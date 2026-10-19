import { readFile, mkdir, writeFile } from 'node:fs/promises';

await mkdir(new URL('../artifacts/', import.meta.url), { recursive: true });
for (const name of ['SongADayAuction', 'SongADayEditions']) {
  const artifact = JSON.parse(await readFile(new URL(`../out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));
  await writeFile(new URL(`../artifacts/${name}.abi.json`, import.meta.url), `${JSON.stringify(artifact.abi, null, 2)}\n`);
}
