import React, { useState } from 'react';

const MODE_LABEL = { live: 'Live', recorded: 'Recorded', 'live+recorded': 'Live + clip', slide: 'Slide' };
const LEVEL_LABEL = { full: 'Follow along', read: 'Read along', none: 'Watch only' };

export default function SessionList({ session }) {
  const [filter, setFilter] = useState('all');
  const demos = session.demos.filter((d) => filter === 'all' || d.followAlong.level === filter);
  return (
    <section>
      <h1>{session.title}</h1>
      <p className="lede">{session.subtitle}</p>
      <p className="meta">{session.date} · {session.length} min · Level {session.level}</p>
      <p className="policy">{session.followAlongPolicy}</p>
      {session.variables?.length > 0 && (
        <div className="policy">
          <strong>Placeholders used in the commands</strong>
          <ul>{session.variables.map((v) => <li key={v.name}><code>{v.name}</code>: {v.meaning}</li>)}</ul>
        </div>
      )}

      <div className="filters" role="group" aria-label="Filter by follow-along level">
        {['all', 'full', 'read', 'none'].map((f) => (
          <button key={f} type="button" className={filter === f ? 'on' : ''} onClick={() => setFilter(f)}>
            {f === 'all' ? 'All demos' : LEVEL_LABEL[f]}
          </button>
        ))}
      </div>

      {session.sections.map((sec) => {
        const items = demos.filter((d) => String(d.section).split('.')[0] === sec.id);
        if (items.length === 0) return null;
        return (
          <div key={sec.id} className="section">
            <h2><span className="secnum">{sec.id}</span> {sec.title}</h2>
            <ul className="demos">
              {items.map((d) => (
                <li key={d.id}>
                  <a href={`#/demo/${d.id}`}>{d.title}</a>
                  <span className={`badge mode-${d.mode.replace('+', '-')}`}>{MODE_LABEL[d.mode]}</span>
                  <span className={`badge lvl-${d.followAlong.level}`}>{LEVEL_LABEL[d.followAlong.level]}</span>
                </li>
              ))}
            </ul>
          </div>
        );
      })}
    </section>
  );
}
