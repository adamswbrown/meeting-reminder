"""One bounded, read-only MCP call. Run with the configured Teams server's venv.
No sampling callback, elicitation callback, arbitrary tool selection or secrets in output.
"""
import asyncio
import json
import os
import sys
from pathlib import Path


async def gather(request):
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    config = json.loads((Path.home() / '.claude.json').read_text())['mcpServers']['teams-chat']
    parameters = StdioServerParameters(command=config['command'], args=config.get('args', []),
                                      env={**os.environ, **config.get('env', {})})
    async with stdio_client(parameters) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            result = await session.call_tool('context_for_meeting', {
                'title': request['title'], 'attendee_emails': request.get('attendee_emails', []),
                'since': '14d',
            })
            payload = result.model_dump(by_alias=True)
            text = '\n'.join(block.get('text', '') for block in payload.get('content', [])
                             if block.get('type') == 'text')
            # The server sometimes reports application errors inside a successful result.
            unavailable = payload.get('isError', False) or not text.strip() or text.startswith(
                ('Failed:', 'Bad argument:', 'Not signed in', 'Authentication', 'Sign in'))
            return {'text': text[:12000], 'unavailable': unavailable, 'truncated': len(text) > 12000}


if __name__ == '__main__':
    try:
        request = json.loads(sys.stdin.read(16000))
        print(json.dumps(asyncio.run(asyncio.wait_for(gather(request), timeout=40))))
    except Exception:
        # Diagnostic type and credentials stay out of the evidence payload.
        print(json.dumps({'text': '', 'unavailable': True, 'truncated': False}))
        sys.exit(1)
