import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const convexDir = path.join(root, "convex");
const forbidden = [
  /gmail\.googleapis\.com\/gmail\/v1\/users\/me\/messages\/send/i,
  /gmail\.googleapis\.com\/gmail\/v1\/users\/me\/messages\/[^"`']+\/modify/i,
  /calendar\.googleapis\.com\/calendar\/v3\/calendars\/[^"`']+\/events[^"`']*method=["']?post/i,
  /\/events\/[^"`']+["'`][\s\S]{0,120}method:\s*["'](?:POST|PATCH|PUT|DELETE)["']/i,
  /https:\/\/www\.googleapis\.com\/auth\/gmail\.(?:modify|send|compose)/i,
  /https:\/\/www\.googleapis\.com\/auth\/calendar(?:\.events)?(?!\.readonly)/i,
];

const files = walk(convexDir).filter((file) => file.endsWith(".ts"));
const violations = [];

for (const file of files) {
  const source = fs.readFileSync(file, "utf8");
  for (const pattern of forbidden) {
    if (pattern.test(source)) {
      violations.push(`${path.relative(root, file)} matched ${pattern}`);
    }
  }
}

if (violations.length) {
  console.error("Google write endpoint/scope guard failed:");
  for (const violation of violations) {
    console.error(`- ${violation}`);
  }
  process.exit(1);
}

function walk(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  return entries.flatMap((entry) => {
    const fullPath = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(fullPath) : [fullPath];
  });
}
