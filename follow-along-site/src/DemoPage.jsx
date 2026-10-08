import React from 'react';
import CodeBlock from './CodeBlock.jsx';

const LEVEL_LABEL = { full: 'Follow along', read: 'Read along', none: 'Watch only' };
const repositoryUrl = import.meta.env.VITE_REPOSITORY_URL;
const sourceRef = import.meta.env.VITE_SOURCE_REF || 'main';

export default function DemoPage({ session, demo }) {
  const fa = demo.followAlong;
  const i = session.demos.findIndex((d) => d.id === demo.id);
  const prev = session.demos[i - 1];
  const next = session.demos[i + 1];
  return (
    <section>
      <p className="crumbs"><a href="#/">{session.title}</a> › Section {demo.section}</p>
      <h1>{demo.title}</h1>
      <div className="follow">
        <p><span className={`badge lvl-${fa.level}`}>{LEVEL_LABEL[fa.level]}</span></p>
        <h2>Goal</h2>
        <p>{fa.goal}</p>

        {fa.level === 'none' && <p className="muted">This demo runs only on the presenter's lab environment. The repository path below has the material.</p>}

        {fa.needs?.length > 0 && (
          <>
            <h2>What you need</h2>
            <ul>{fa.needs.map((n, k) => <li key={k}>{n}</li>)}</ul>
          </>
        )}

        {fa.steps?.length > 0 && (
          <>
            <h2>Steps</h2>
            <ol className="steps">
              {fa.steps.map((s, k) => (
                <li key={k}>
                  <div className="action"><strong>{s.title}</strong></div>
                  <p>{s.instructions}</p>
                  {s.command && <CodeBlock code={s.command} />}
                  <div className="check"><span className="label">You should see</span> {s.check}</div>
                </li>
              ))}
            </ol>
          </>
        )}

        {fa.troubleshooting?.length > 0 && (<><h2>Troubleshooting</h2><ul>{fa.troubleshooting.map((t, k) => <li key={k}>{t}</li>)}</ul></>)}
        {fa.cleanup?.length > 0 && (<><h2>Clean up</h2><ul>{fa.cleanup.map((c, k) => <li key={k}>{c}</li>)}</ul></>)}
        {fa.repoPaths?.length > 0 && (<><h2>In the repository</h2><ul>{fa.repoPaths.map((p, k) => <li key={k}>{repositoryUrl ? <a href={`${repositoryUrl}/blob/${encodeURIComponent(sourceRef)}/${p.split('/').map(encodeURIComponent).join('/')}`}><code>{p}</code></a> : <code>{p}</code>}</li>)}</ul></>)}
      </div>
      <nav className="pager">
        {prev ? <a href={`#/demo/${prev.id}`}>← {prev.title}</a> : <span />}
        {next ? <a href={`#/demo/${next.id}`}>{next.title} →</a> : <span />}
      </nav>
    </section>
  );
}
