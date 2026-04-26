#!/usr/bin/env node
// sync-memory-to-db.js
// Reads all .md files from ~/.claude/memory/ and upserts into claude_memory table.
// Run: node sync-memory-to-db.js
// Or add to package.json scripts: "memory:sync": "node sync-memory-to-db.js"

const fs   = require('fs');
const path = require('path');

const MEMORY_DIR = path.join(process.env.HOME, '.claude/projects/-Users-b-lamoutlook-com/memory');
const SB_URL     = process.env.SUPABASE_URL     || 'https://zyoszbmahxnfcokuzkuv.supabase.co';
const SB_KEY     = process.env.SUPABASE_SERVICE_KEY || process.env.SUPABASE_ANON_KEY;

if (!SB_KEY) {
  console.error('Set SUPABASE_SERVICE_KEY or SUPABASE_ANON_KEY');
  process.exit(1);
}

function parseFrontmatter(raw) {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { meta: {}, content: raw };
  const meta = {};
  match[1].split('\n').forEach(line => {
    const [k, ...v] = line.split(':');
    if (k && v.length) meta[k.trim()] = v.join(':').trim();
  });
  return { meta, content: match[2].trim() };
}

async function sync() {
  const files = fs.readdirSync(MEMORY_DIR).filter(f => f.endsWith('.md') && f !== 'MEMORY.md');
  console.log(`Syncing ${files.length} memory files to Supabase…`);

  let ok = 0, failed = 0;

  for (const file of files) {
    const raw = fs.readFileSync(path.join(MEMORY_DIR, file), 'utf8');
    const { meta, content } = parseFrontmatter(raw);

    const payload = {
      file_name:   file,
      memory_name: meta.name    || file.replace('.md',''),
      description: meta.description || null,
      type:        meta.type    || null,
      content,
      synced_at:   new Date().toISOString()
    };

    const res = await fetch(`${SB_URL}/rest/v1/claude_memory`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': SB_KEY,
        'Authorization': `Bearer ${SB_KEY}`,
        'Prefer': 'resolution=merge-duplicates,return=minimal',
        'on-conflict': 'file_name'
      },
      body: JSON.stringify(payload)
    });

    if (res.ok) {
      ok++;
      process.stdout.write('.');
    } else {
      const err = await res.text();
      console.error(`\nFailed: ${file} — ${err}`);
      failed++;
    }
  }

  console.log(`\nDone. ${ok} synced, ${failed} failed.`);
}

sync().catch(console.error);
