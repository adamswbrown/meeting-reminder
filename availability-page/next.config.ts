import type { NextConfig } from "next";
import path from "node:path";

const nextConfig: NextConfig = {
  // Pin Turbopack's project root to this directory. Without it, Next.js walks
  // up looking for a lockfile and can land on /Users/<you>/package-lock.json
  // from an unrelated project in your home dir.
  turbopack: {
    root: path.resolve(__dirname),
  },
};

export default nextConfig;
