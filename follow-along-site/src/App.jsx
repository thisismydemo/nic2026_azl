import React, { useEffect, useState } from 'react';
import session from './content.json';
import SessionList from './SessionList.jsx';
import DemoPage from './DemoPage.jsx';

// Minimal hash router: #/ lists the demos, #/demo/<id> shows one demo's follow-along page.
function parse(hash) {
  return hash.replace(/^#\/?/, '').split('/').filter(Boolean);
}

export default function App() {
  const [parts, setParts] = useState(parse(window.location.hash));
  useEffect(() => {
    const on = () => {
      setParts(parse(window.location.hash));
      window.scrollTo(0, 0);
    };
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);

  const [view, id] = parts;
  const demo = view === 'demo' ? session.demos.find((d) => d.id === id) : null;
  let body;
  if (demo) body = <DemoPage session={session} demo={demo} />;
  else if (view === 'demo') body = <p>Demo not found. <a href="#/">Back to the list</a>.</p>;
  else body = <SessionList session={session} />;
  return (
    <div className="app">
      <header className="top">
        <div className="bifrost" aria-hidden="true" />
        <a href="#/" className="brand">{session.title}: follow along</a>
      </header>
      <main>{body}</main>
      <footer>Attendee pages. Replace the placeholders in the commands with your own values and run nothing against an environment you do not own.</footer>
    </div>
  );
}
