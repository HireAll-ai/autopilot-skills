// Factory reporter: pairs every recorded video with a human-readable
// description of what it demonstrates, and assembles VIDEOS.md — the
// operator-facing map of all scenarios (prefixed with the e2e/README.md
// narrative when the repo provides one).
//
// Description source, in priority order:
//   1. a 'description' annotation on the test
//      (test('t', { annotation: { type: 'description', description: '…' } }, fn)
//       or testInfo.annotations.push(...) in the body)
//   2. the test title.
import fs from 'node:fs';
import path from 'node:path';

export default class FactoryReporter {
  onBegin() {
    this.entries = [];
    this.outDir = process.env.E2E_OUT_DIR || 'factory-artifacts/e2e-results';
  }

  onTestEnd(test, result) {
    const annotations = [...(test.annotations || []), ...(result.annotations || [])];
    const desc = annotations.find((a) => a.type === 'description')?.description || '';
    const videos = (result.attachments || [])
      .filter((a) => a.name === 'video' && a.path)
      .map((a) => a.path);
    this.entries.push({
      title: test.title,
      file: path.relative(process.cwd(), test.location.file),
      status: result.status,
      durationMs: result.duration,
      description: desc,
      videos,
    });
  }

  onEnd() {
    fs.mkdirSync(this.outDir, { recursive: true });

    let md = '# E2E видео — что демонстрирует каждый ролик\n\n';
    const narrativePath = path.join('e2e', 'README.md');
    if (fs.existsSync(narrativePath)) {
      md += '## Логика фичи и тестирования\n\n';
      md += fs.readFileSync(narrativePath, 'utf8').trim() + '\n\n---\n\n';
    }
    md += '## Сценарии\n\n';

    for (const e of this.entries) {
      const mark = e.status === 'passed' ? '✅' : e.status === 'skipped' ? '⏭️' : '❌';
      md += `### ${mark} ${e.title}\n\n`;
      md += (e.description || '_нет description-аннотации — смотри название теста_') + '\n\n';
      md += `Файл: \`${e.file}\` · статус: ${e.status} · ${Math.round(e.durationMs / 1000)}s\n\n`;
      for (const v of e.videos) {
        md += `Видео: \`${path.relative(process.cwd(), v)}\`\n\n`;
        try {
          fs.writeFileSync(
            path.join(path.dirname(v), 'DESCRIPTION.md'),
            `# ${e.title}\n\n${e.description || '(см. название теста)'}\n\nСтатус: ${e.status}\nФайл теста: ${e.file}\n`,
          );
        } catch {
          /* sidecar is best-effort */
        }
      }
    }

    fs.writeFileSync(path.join(this.outDir, 'VIDEOS.md'), md);
    fs.writeFileSync(path.join(this.outDir, 'manifest.json'), JSON.stringify(this.entries, null, 2));
  }
}
