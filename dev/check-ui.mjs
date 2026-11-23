// Browser-Durchlauf für Team Planning gegen eine laufende Redmine-Instanz.
// ÄNDERT DATEN (Tickets, Zeiten, Planung): nur über dev/check-ui.sh starten,
// das die Datenbank vorher sichert und danach zurücksetzt.
//
// Regressionen (Browser-Test 23.11.2026):
//  - Stunden planen schickte PATCH an /issues/0 (urlFor ersetzte nur "/issues/0/")
//  - Pool ließ sich nicht ziehen: [hidden] wirkte nicht gegen .tp-cards { display: flex }
//  - Ziehen am Titel (Link) startete nicht
//  - Abhaken-Menü: Einträge überlappten (Theme-Knöpfe mit fester Höhe 32px)
//  - Buchen im Block: leeres Datum führte zu "Datum muss ausgefüllt werden"
//
// Aufruf: dev/check-ui.sh            (Container redmine-klar-theme, http://localhost:3080)
import { chromium } from 'playwright';
const S = process.argv[2] || '/tmp', base = process.argv[3] || 'http://localhost:3080';
const failures = [];
const expect = (ok, text) => { if (!ok) failures.push(text); };
const log = (...a) => console.log(...a);
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1600, height: 1000 } });
  const errs = []; p.on('pageerror', e => errs.push('JS ' + e.message)); p.on('console', m => m.type() === 'error' && errs.push('console ' + m.text()));
  const clearT = () => p.evaluate(() => { const t = document.getElementById('tp-toast'); if (t) t.innerHTML = ''; }); const toast = async () => { await p.waitForSelector('#tp-toast .tp-toast', { timeout: 5000 }); return (await p.locator('#tp-toast .tp-toast span').innerText()); };
  const idle = () => p.waitForTimeout(400);
  async function drag(src, dst) { await clearT();
    const s = await p.locator(src).first().boundingBox(), t = await p.locator(dst).first().boundingBox();
    await p.mouse.move(s.x + 40, s.y + 12); await p.mouse.down(); await p.mouse.move(s.x + 60, s.y + 30, { steps: 4 });
    await p.mouse.move(t.x + 40, t.y + 10, { steps: 14 }); await p.mouse.up(); await idle();
  }
  await p.goto(base + '/login'); await p.fill('#username', 'admin'); await p.fill('#password', 'admin'); await p.click('#login-submit');
  await p.goto(base + '/team_planning');
  const cur = await p.locator('.tp-board').getAttribute('data-current');
  const curList = `.tp-cards[data-location="${cur}"]`;
  const first = await p.locator('.tp-cards[data-location=backlog] .tp-card').first().getAttribute('data-issue-id');
  await drag(`.tp-card[data-issue-id="${first}"]`, curList);
  log('1 drag:', await toast(), '| in current:', await p.locator(`${curList} .tp-card[data-issue-id="${first}"]`).count());
  await p.click('#tp-toast button'); await idle(); await p.waitForTimeout(500);
  log('2 undo -> backlog:', await p.locator(`.tp-cards[data-location=backlog] .tp-card[data-issue-id="${first}"]`).count());

  // Langer Backlog: scrollt in sich, Ziehen vom Ende der Liste und Weiterscrollen am Rand
  const bl = p.locator('.tp-cards[data-location=backlog]');
  const scrollable = await bl.evaluate(l => l.scrollHeight > l.clientHeight + 10);
  expect(scrollable, 'Backlog scrollt nicht in sich (Liste nicht begrenzt)');
  const pageHeight = await p.evaluate(() => document.documentElement.scrollHeight);
  expect(pageHeight < 1600, 'Seite wird durch den Backlog zu lang: ' + pageHeight);
  await bl.evaluate(l => { l.scrollTop = l.scrollHeight; });
  const lastId = await bl.locator('.tp-card').last().getAttribute('data-issue-id');
  if (process.env.DEBUG) {
    p.on('request', r => r.url().includes('/team_planning/issues') && log('REQ', r.method(), r.url(), r.postData()));
    log('DEBUG last', lastId, await bl.locator('.tp-card').last().boundingBox(), await bl.boundingBox(), await p.locator(curList).boundingBox());
  }
  await drag(`.tp-cards[data-location=backlog] .tp-card[data-issue-id="${lastId}"]`, curList);
  log('2b drag from end of backlog:', await toast(), '| in current:', await p.locator(`${curList} .tp-card[data-issue-id="${lastId}"]`).count());
  expect(await p.locator(`${curList} .tp-card[data-issue-id="${lastId}"]`).count() === 1, 'Ziehen vom Ende des Backlogs');
  await clearT(); await p.click('#tp-toast button').catch(() => {}); await idle(); await p.waitForTimeout(500);
  await bl.evaluate(l => { l.scrollTop = 0; });
  const bb = await bl.boundingBox(), fc = await bl.locator('.tp-card').first().boundingBox();
  await p.mouse.move(fc.x + 40, fc.y + 12); await p.mouse.down(); await p.mouse.move(fc.x + 50, fc.y + 30, { steps: 4 });
  await p.mouse.move(bb.x + 60, bb.y + bb.height - 8, { steps: 10 }); await p.waitForTimeout(900);
  const scrolled = await bl.evaluate(l => l.scrollTop);
  await p.mouse.move(fc.x + 40, fc.y + 12, { steps: 4 }); await p.mouse.up(); await idle(); await p.waitForTimeout(400);
  log('2c auto-scroll while dragging:', scrolled);
  expect(scrolled > 50, 'Beim Ziehen an den unteren Rand scrollt der Backlog nicht: ' + scrolled);
  await p.locator('.tp-cards[data-location=backlog]').evaluate(l => { l.scrollTop = 0; });
  await drag(`.tp-card[data-issue-id="${first}"]`, curList); await toast();
  const card = `${curList} .tp-card[data-issue-id="${first}"]`;
  await p.hover(card); await p.click(`${card} [data-tp-hours]`); await clearT(); await p.click('.tp-pop .tp-chip >> text="2 h"'); await toast(); await idle();
  const hoursText = await p.locator(`${card} [data-tp-hours]`).innerText(); log('3 hours:', hoursText); expect(hoursText === '0 / 2 h', 'Stunden planen: ' + hoursText);
  await p.click(`${card} [data-tp-menu]`); await clearT(); await p.click('.tp-pop-item >> text=Als Dauerthema markieren'); await toast(); await idle();
  log('4 standing:', await p.locator(`.tp-col.is-current .tp-standing .tp-card[data-issue-id="${first}"]`).count());
  await p.click(`.tp-col.is-current .tp-standing .tp-card[data-issue-id="${first}"] [data-tp-menu]`); await clearT(); await p.click('.tp-pop-item >> text=Wieder normale Aufgabe'); await toast(); await idle();
  log('5 back normal:', await p.locator(card).count());
  const next = JSON.parse(await p.locator('.tp-board').getAttribute('data-futures'))[0][0];
  const nextCol = p.locator('.tp-col').filter({ has: p.locator(`.tp-cards[data-location="${next}"]`) });
  await nextCol.hover(); await nextCol.locator('[data-tp-absence]').click(); await clearT(); await p.click('.tp-pop .tp-chip >> text="2 Tage"'); await toast(); await idle();
  log('6 absence:', (await nextCol.locator('.tp-col-count').innerText()), '|', await nextCol.locator('[data-tp-absence]').innerText());
  await nextCol.locator('[data-tp-add]').click(); await p.fill('.tp-add-title', 'E2E Aufgabe'); await p.keyboard.press('Enter'); await toast(); await idle();
  log('7 add:', await nextCol.locator('.tp-card', { hasText: 'E2E Aufgabe' }).count(), '| form open:', await nextCol.locator('.tp-add-form').count(), '| focus:', await p.evaluate(() => document.activeElement.className));
  await p.keyboard.press('Escape');
  await p.click('[data-tp-backlog=pool]'); await idle();
  const poolCard = await p.locator('.tp-cards[data-location=pool] .tp-card').first().getAttribute('data-issue-id');
  await drag(`.tp-card[data-issue-id="${poolCard}"]`, `.tp-cards[data-location="${next}"]`);
  const poolToast = await toast(); log('8 pool:', poolToast); expect(/zugewiesen/.test(poolToast), 'Pool ziehen: ' + poolToast);
  await p.screenshot({ path: S + '/e2e-board.png' });
  await p.click(`${card} [data-tp-check]`); await p.waitForSelector('.tp-pop .tp-done-option');
  log('9 done options:', (await p.locator('.tp-pop').innerText()).replace(/\n/g, ' | '));
  await p.screenshot({ path: S + '/e2e-done.png' });
  const boxes = await p.locator('.tp-pop .tp-pop-item').evaluateAll(els => els.map(e => { const r = e.getBoundingClientRect(); return [r.top, r.bottom]; }));
  expect(boxes.every((b, i) => i === 0 || b[0] >= boxes[i - 1][1] - 1), 'Abhaken-Menü: Einträge überlappen');
  await clearT(); await p.keyboard.press('Enter'); log('9 done:', await toast()); await idle();
  log('9 card done:', await p.locator(`${card}.is-done`).count());
  // Abschluss
  await p.goto(base + '/team_planning/close');
  log('10 submit disabled before:', await p.locator('.tp-close-form input[type=submit]').isDisabled());
  if (await p.locator('[data-tp-decide-all]').count()) await p.click('[data-tp-decide-all]');
  for (const g of await p.locator('.tp-close-form .tp-seg').all()) { const r = g.locator('input[value=next]'); if (!(await g.locator('input:checked').count())) await r.check({ force: true }); }
  await p.fill('#review_good', 'E2E gut'); await p.fill('#focus', 'E2E Fokus');
  await p.screenshot({ path: S + '/e2e-close.png', fullPage: true });
  await p.click('.tp-close-form input[type=submit]'); await p.waitForLoadState();
  log('10 closed:', await p.locator('.flash.notice, #flash_notice').innerText(), '| url', p.url());
  // Regression: in der eingeklappten Vorwoche (64 px) ragte "abgeschlossen" über den Rand
  const foldOverflow = await p.locator('.tp-col.is-past.is-folded').evaluate((col) => {
    const right = col.getBoundingClientRect().right;
    return [...col.querySelectorAll('.tp-past-fold > *')].map((e) => e.getBoundingClientRect().right - right).filter((d) => d > 0.5);
  });
  log('10b folded past overflow:', JSON.stringify(foldOverflow));
  expect(foldOverflow.length === 0, 'Text ragt aus der eingeklappten Vorwoche: ' + foldOverflow);
  await p.click('[data-tp-past]'); log('11 past rows:', await p.locator('.tp-past-row').count());
  // Teamrunde
  await p.goto(base + '/team_planning/team'); await p.fill('#tp-round-notes', 'E2E Notiz'); await p.waitForTimeout(1200);
  log('12 notes:', await p.locator('[data-tp-notes-state]').innerText(), '| persons', await p.locator('.tp-person').count());
  await p.screenshot({ path: S + '/e2e-team.png', fullPage: true });
  await p.goto(base + '/team_planning/team?mode=project'); log('12 projects:', await p.locator('.tp-panel h3').count());
  // Meine Seite
  await p.goto(base + '/my/page');
  if (!(await p.locator('#block-team_plan').count())) await p.selectOption('#block-select', 'team_plan');
  await p.waitForSelector('#block-team_plan .tp-widget', { timeout: 8000 });
  await p.goto(base + '/my/page');
  log('13 future period, booking hint:', await p.locator('#block-team_plan .tp-hint').allInnerTexts());
  await p.click('#block-team_plan .tp-wnav a'); await p.waitForLoadState();
  log('13 past period:', await p.locator('#block-team_plan .tp-wnav').innerText());
  // Regression: Redmines defaultFocus setzt beim Laden den Fokus ins erste Stundenfeld,
  // dadurch war die Zusatzzeile der ersten Zeile immer aufgeklappt
  const openOnLoad = await p.locator('#block-team_plan .tp-wmore:visible').count();
  log('13 more open on load:', openOnLoad);
  expect(openOnLoad === 0, 'Zusatzzeile beim Laden aufgeklappt: ' + openOnLoad);
  const row = p.locator('#block-team_plan .tp-wrow').first();
  await row.locator('[data-hours="1"]').click(); await p.waitForLoadState(); await p.waitForTimeout(800);
  log('13 widget toast:', await toast());
  const r2 = p.locator('#block-team_plan .tp-wrow').first();
  await r2.locator('input[name=hours]').click(); const moreVisible = await r2.locator('.tp-wmore').isVisible(); log('13 more visible:', moreVisible); expect(moreVisible, 'Zusatzzeile klappt beim Klick nicht auf');
  await r2.locator('input[name=hours]').fill('1,5'); await r2.locator('input[name=comments]').fill('E2E Kommentar'); await r2.locator('input[name=hours]').press('Enter');
  await p.waitForLoadState(); await p.waitForTimeout(800); const typed = await toast(); log('13 typed toast:', typed); expect(/gebucht/.test(typed), 'Buchen: ' + typed);
  await p.screenshot({ path: S + '/e2e-widget.png', fullPage: true });
  // Nur lesen
  const c2 = await b.newContext({ viewport: { width: 1600, height: 1000 } }); const q = await c2.newPage();
  q.on('pageerror', e => errs.push('JS(member) ' + e.message));
  await q.goto(base + '/login'); await q.fill('#username', process.env.MEMBER_LOGIN); await q.fill('#password', 'tp-check-1234'); await q.click('#login-submit');
  await q.goto(base + '/team_planning?user_id=1');
  const readonly = await q.locator('.tp-board.is-readonly').count(), menus = await q.locator('.tp-menu-btn:visible').count(), closeBtn = await q.locator('a.tp-btn-primary').count();
  log('14 readonly:', readonly, '| menu visible:', menus, '| close btn:', closeBtn);
  expect(readonly === 1 && menus === 0 && closeBtn === 0, 'Fremde Planung ist für Mitarbeitende nicht nur lesbar');
  log('errors', errs); expect(errs.length === 0, 'Fehler im Browser: ' + errs.join('; '));
  await b.close();
  if (failures.length) { console.error('FEHLER:\n- ' + failures.join('\n- ')); process.exit(1); }
  console.log('Team Planning: Browser-Durchlauf ohne Fehler');
})().catch(e => { console.error('ABBRUCH', e.message); process.exit(1); });
