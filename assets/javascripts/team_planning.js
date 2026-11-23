// Team Planning: Board (Ziehen, Menüs, Abhaken), Abschluss, Teamrunde, Block auf Meine Seite.
// Ohne Bibliotheken; Änderungen gehen als JSON an team_planning_items, danach
// wird das Board neu geladen. Hinweise mit "Rückgängig" unten in der Mitte.
(function () {
  'use strict';

  var i18n = {};
  var popover = null;
  var popoverCleanup = null;

  function $(selector, root) { return (root || document).querySelector(selector); }
  function $$(selector, root) { return Array.prototype.slice.call((root || document).querySelectorAll(selector)); }

  function loadTexts() {
    var node = document.getElementById('tp-i18n');
    if (node) { try { i18n = JSON.parse(node.textContent); } catch (e) { i18n = {}; } }
  }

  function t(key) { return i18n[key] || key; }

  // Vorlage mit Ticket 0, z. B. /team_planning/issues/0/move oder /team_planning/issues/0?user_id=3
  function urlFor(template, issueId) {
    return template.replace(/\/issues\/0(?=[\/?]|$)/, '/issues/' + issueId);
  }

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : '';
  }

  function request(method, url, body) {
    var options = {
      method: method,
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json', 'X-CSRF-Token': csrfToken(), 'X-Requested-With': 'XMLHttpRequest' }
    };
    if (body && method !== 'GET') {
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    return fetch(url, options).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) {
        if (!response.ok || data.error) { throw new Error(data.error || t('error')); }
        return data;
      });
    });
  }

  // --- Hinweise ---------------------------------------------------------------

  var toastTimer = null;
  function toast(message, undo) {
    var box = $('#tp-toast');
    if (!box) {
      box = document.createElement('div');
      box.id = 'tp-toast';
      box.setAttribute('role', 'status');
      box.setAttribute('aria-live', 'polite');
      document.body.appendChild(box);
    }
    box.innerHTML = '';
    var inner = document.createElement('div');
    inner.className = 'tp-toast';
    var text = document.createElement('span');
    text.textContent = message;
    inner.appendChild(text);
    if (undo && undo.url) {
      var button = document.createElement('button');
      button.type = 'button';
      button.textContent = t('undo');
      button.addEventListener('click', function () {
        box.innerHTML = '';
        request(undo.method || 'POST', undo.url, undo.params || {}).then(function (data) { afterChange(data, true); }).catch(showError);
      });
      inner.appendChild(button);
    }
    box.appendChild(inner);
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { box.innerHTML = ''; }, 7000);
  }

  function showError(error) { toast(error.message || t('error')); }

  // Nach einer Änderung: Board neu laden, sonst (Meine Seite) die Seite
  function afterChange(data, silent) {
    var board = document.getElementById('team-planning-board');
    if (board) {
      reloadBoard().then(function () { if (!silent && data.message) toast(data.message, data.undo); });
    } else {
      try { sessionStorage.setItem('tp-toast', JSON.stringify(silent ? {} : data)); } catch (e) { /* ohne Speicher */ }
      window.location.reload();
    }
  }

  function showStoredToast() {
    try {
      var stored = sessionStorage.getItem('tp-toast');
      sessionStorage.removeItem('tp-toast');
      if (stored) {
        var data = JSON.parse(stored);
        if (data.message) toast(data.message, data.undo);
      }
    } catch (e) { /* ohne Speicher */ }
  }

  // --- Board -------------------------------------------------------------------

  var boardState = { backlog: 'backlog', filterText: '', filterProject: '', pastOpen: false, pastOn: null, addOpen: null };

  function board() { return $('.tp-board'); }
  function editable() { var b = board(); return b && b.dataset.editable === 'true'; }

  // Board neu laden; seitliche und vertikale Scroll-Positionen der Listen bleiben
  function reloadBoard() {
    var container = document.getElementById('team-planning-board');
    var scroll = board() ? board().scrollLeft : 0;
    var lists = {};
    $$('.tp-cards', container).forEach(function (list) { lists[list.dataset.location] = list.scrollTop; });
    var url = container.dataset.boardUrl;
    if (boardState.pastOn) url += (url.indexOf('?') < 0 ? '?' : '&') + 'past=' + encodeURIComponent(boardState.pastOn);
    return fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function (response) { return response.text(); })
      .then(function (html) {
        container.innerHTML = html;
        if (board()) board().scrollLeft = scroll;
        applyBoardState();
        $$('.tp-cards', container).forEach(function (list) {
          if (lists[list.dataset.location]) list.scrollTop = lists[list.dataset.location];
        });
      });
  }

  // Spalten enden am unteren Fensterrand: Abstand des Boards vom Seitenanfang als Variable
  function fitBoard() {
    var b = board();
    if (!b) return;
    var top = b.getBoundingClientRect().top + window.scrollY;
    document.documentElement.style.setProperty('--tp-board-top', Math.round(top) + 'px');
  }

  function applyBoardState() {
    var b = board();
    if (!b) return;
    fitBoard();
    $$('[data-tp-backlog]', b).forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.dataset.tpBacklog === boardState.backlog));
    });
    $$('.is-backlog .tp-cards', b).forEach(function (list) { list.hidden = list.dataset.location !== boardState.backlog; });
    var hint = $('.tp-pool-hint', b);
    if (hint) hint.hidden = boardState.backlog !== 'pool';
    var text = $('.tp-filter-text', b);
    var project = $('.tp-filter-project', b);
    if (text) text.value = boardState.filterText;
    if (project) project.value = boardState.filterProject;
    filterBacklog();
    var past = $('.tp-col.is-past', b);
    if (past) past.classList.toggle('is-folded', !boardState.pastOpen);
    var addButton = boardState.addOpen ? $('[data-tp-add="' + boardState.addOpen + '"]', b) : null;
    if (addButton) openAddForm(addButton);
  }

  function filterBacklog() {
    var q = boardState.filterText.toLowerCase();
    $$('.is-backlog .tp-card', board()).forEach(function (card) {
      var match = (!q || card.dataset.subject.indexOf(q) >= 0) &&
                  (!boardState.filterProject || card.dataset.projectId === boardState.filterProject);
      card.hidden = !match;
    });
  }

  function locations() {
    try { return JSON.parse(board().dataset.locations); } catch (e) { return []; }
  }

  function labelFor(location) {
    var found = locations().filter(function (entry) { return entry[0] === location; })[0];
    return found ? found[1] : location;
  }

  function move(issueId, to, position) {
    return request('POST', urlFor(board().dataset.moveUrl, issueId), { to: to, position: position })
      .then(function (data) { afterChange(data); }).catch(function (error) { showError(error); reloadBoard(); });
  }

  // Ziehen und Ablegen mit der Maus (Touch: über das Menü "Verschieben nach")
  var drag = null;
  var suppressClickUntil = 0;

  function onClickCapture(event) {
    if (Date.now() < suppressClickUntil && event.target.closest('.tp-board')) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  function onPointerDown(event) {
    var card = event.target.closest('.tp-board .tp-card');
    if (!card || event.button !== 0 || event.pointerType === 'touch' || !editable()) return;
    // Auch über Titel und Nummer ziehbar (Links); Knöpfe und Felder nicht
    if (event.target.closest('button, input, select, textarea')) return;
    drag = { card: card, x: event.clientX, y: event.clientY, active: false };
  }

  // Beim Ziehen am Rand weiterscrollen: Liste unter dem Zeiger, Board seitlich,
  // Fenster oben und unten. Läuft, solange gezogen wird, auch ohne Mausbewegung.
  var EDGE = 48;
  function autoScroll() {
    if (!drag || !drag.active) return;
    var x = drag.lastX, y = drag.lastY;
    var speed = function (distance) { return Math.ceil((EDGE - distance) / 4); };
    var target = document.elementFromPoint(x, y);
    var list = target && target.closest('.tp-board .tp-cards, .tp-board .tp-standing');
    if (list && list.scrollHeight > list.clientHeight) {
      var r = list.getBoundingClientRect();
      if (y < r.top + EDGE) list.scrollTop -= speed(y - r.top);
      else if (y > r.bottom - EDGE) list.scrollTop += speed(r.bottom - y);
    }
    var b = board();
    var bounds = b.getBoundingClientRect();
    if (x > bounds.right - EDGE) b.scrollLeft += speed(bounds.right - x);
    else if (x < bounds.left + EDGE) b.scrollLeft -= speed(x - bounds.left);
    if (y < EDGE) window.scrollBy(0, -speed(y));
    else if (y > window.innerHeight - EDGE) window.scrollBy(0, speed(window.innerHeight - y));
    placeCard(x, y);
    drag.frame = requestAnimationFrame(autoScroll);
  }

  function onPointerMove(event) {
    if (!drag) return;
    if (!drag.active) {
      if (Math.abs(event.clientX - drag.x) + Math.abs(event.clientY - drag.y) < 6) return;
      var rect = drag.card.getBoundingClientRect();
      drag.active = true;
      drag.dx = event.clientX - rect.left;
      drag.dy = event.clientY - rect.top;
      drag.from = drag.card.closest('.tp-cards');
      drag.fromIndex = $$('.tp-card', drag.from).indexOf(drag.card);
      drag.ghost = drag.card.cloneNode(true);
      drag.ghost.classList.add('tp-ghost');
      drag.ghost.style.width = rect.width + 'px';
      document.body.appendChild(drag.ghost);
      drag.card.classList.add('is-dragging');
      document.body.classList.add('tp-dragging');
      closePopover();
      drag.frame = requestAnimationFrame(autoScroll);
    }
    event.preventDefault();
    drag.lastX = event.clientX;
    drag.lastY = event.clientY;
    drag.ghost.style.left = (event.clientX - drag.dx) + 'px';
    drag.ghost.style.top = (event.clientY - drag.dy) + 'px';
    placeCard(event.clientX, event.clientY);
  }

  // Karte an die Stelle unter dem Zeiger legen (Vorschau; gespeichert wird beim Loslassen)
  function placeCard(x, y) {
    var target = document.elementFromPoint(x, y);
    var list = target && target.closest('.tp-board .tp-cards');
    if (!list) {
      var column = target && target.closest('.tp-board .tp-col:not(.is-past)');
      list = column && $$('.tp-cards', column).filter(function (l) { return !l.hidden && !l.classList.contains('tp-standing-cards'); })[0];
    }
    $$('.tp-drop').forEach(function (node) { if (node !== list) node.classList.remove('tp-drop'); });
    if (!list || list.hidden) return;
    list.classList.add('tp-drop');
    var others = $$('.tp-card', list).filter(function (c) { return c !== drag.card && !c.hidden; });
    var before = others.filter(function (c) { var r = c.getBoundingClientRect(); return y < r.top + r.height / 2; })[0];
    if (before) {
      if (drag.card.nextElementSibling !== before) list.insertBefore(drag.card, before);
    } else if (list.lastElementChild !== drag.card) {
      list.appendChild(drag.card);
    }
  }

  function onPointerUp() {
    if (!drag) return;
    var current = drag;
    drag = null;
    if (!current.active) return;
    cancelAnimationFrame(current.frame);
    // Der Klick direkt nach dem Loslassen öffnet keinen Link
    suppressClickUntil = Date.now() + 400;
    current.ghost.remove();
    document.body.classList.remove('tp-dragging');
    $$('.tp-drop').forEach(function (node) { node.classList.remove('tp-drop'); });
    var list = current.card.closest('.tp-cards');
    var to = list.dataset.location;
    var index = $$('.tp-card', list).indexOf(current.card);
    var from = current.from.dataset.location;
    if (list === current.from && (index === current.fromIndex || to === 'backlog' || to === 'pool')) {
      current.card.classList.remove('is-dragging');
      reloadBoard();
      return;
    }
    if (to === 'pool') { reloadBoard(); return; }
    move(current.card.dataset.issueId, to, (to === 'backlog') ? null : index);
    if (from === to) return;
  }

  // --- Popover -----------------------------------------------------------------

  function closePopover() {
    if (popover) { popover.remove(); popover = null; }
    if (popoverCleanup) { popoverCleanup(); popoverCleanup = null; }
  }

  function openPopover(anchor, build) {
    closePopover();
    popover = document.createElement('div');
    popover.className = 'tp-pop';
    popover.setAttribute('role', 'dialog');
    build(popover);
    document.body.appendChild(popover);
    var rect = anchor.getBoundingClientRect();
    var width = popover.offsetWidth;
    var height = popover.offsetHeight;
    var left = Math.max(12, Math.min(rect.left, window.innerWidth - width - 12));
    var top = rect.bottom + 6;
    if (top + height > window.innerHeight - 12) top = Math.max(12, rect.top - height - 6);
    popover.style.left = (left + window.scrollX) + 'px';
    popover.style.top = (top + window.scrollY) + 'px';
    var first = popover.querySelector('textarea, input, select, button:not([disabled])');
    if (first) first.focus();
    var onDocument = function (event) {
      if (popover && !popover.contains(event.target) && !anchor.contains(event.target)) closePopover();
    };
    var onKey = function (event) { if (event.key === 'Escape') { closePopover(); anchor.focus(); } };
    setTimeout(function () { document.addEventListener('click', onDocument); }, 0);
    document.addEventListener('keydown', onKey);
    popoverCleanup = function () {
      document.removeEventListener('click', onDocument);
      document.removeEventListener('keydown', onKey);
    };
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function item(label, onClick, options) {
    var button = el('button', 'tp-pop-item');
    button.type = 'button';
    if (options && options.html) button.appendChild(options.html); else button.textContent = label;
    if (options && options.disabled) button.disabled = true;
    button.addEventListener('click', function () { closePopover(); onClick(); });
    return button;
  }

  function chip(label, onClick, pressed) {
    var button = el('button', 'tp-chip', label);
    button.type = 'button';
    button.setAttribute('aria-pressed', String(!!pressed));
    button.addEventListener('click', function () { closePopover(); onClick(); });
    return button;
  }

  function updateItem(issueId, attributes) {
    return request('PATCH', urlFor(board().dataset.itemUrl, issueId), attributes)
      .then(function (data) { afterChange(data); }).catch(showError);
  }

  function hoursPopover(card) {
    openPopover(card.querySelector('[data-tp-hours]') || card, function (pop) {
      var pad = el('div', 'tp-pop-pad');
      pad.appendChild(el('strong', null, t('hoursTitle')));
      pad.appendChild(el('div', 'tp-hint', t('hoursHint')));
      var chips = el('div', 'tp-chips');
      var planned = parseFloat(card.dataset.planned || '0');
      [1, 2, 4, 8].forEach(function (h) {
        chips.appendChild(chip(h === 8 ? t('day') : h + ' h', function () { updateItem(card.dataset.issueId, { planned_hours: h }); }, planned === h));
      });
      pad.appendChild(chips);
      var form = el('form', 'tp-inline');
      var input = el('input');
      input.type = 'text';
      input.inputMode = 'decimal';
      input.placeholder = t('hoursOther');
      input.setAttribute('aria-label', t('hoursOther'));
      form.appendChild(input);
      var submit = el('button', 'tp-btn tp-btn-sm', t('set'));
      submit.type = 'submit';
      form.appendChild(submit);
      form.addEventListener('submit', function (event) {
        event.preventDefault();
        closePopover();
        updateItem(card.dataset.issueId, { planned_hours: input.value });
      });
      pad.appendChild(form);
      if (planned) pad.appendChild(item(t('hoursNone'), function () { updateItem(card.dataset.issueId, { planned_hours: '' }); }));
      pop.appendChild(pad);
    });
  }

  function longPopover(card, anchor) {
    openPopover(anchor, function (pop) {
      var pad = el('div', 'tp-pop-pad');
      pad.appendChild(el('strong', null, t('longTitle')));
      pad.appendChild(el('div', 'tp-hint', t('longHint')));
      var chips = el('div', 'tp-chips');
      var futures = [];
      try { futures = JSON.parse(board().dataset.futures); } catch (e) { futures = []; }
      futures.forEach(function (entry) {
        chips.appendChild(chip(t('until') + ' ' + entry[1].replace(/^\D+/, '').split('–').pop(), function () {
          updateItem(card.dataset.issueId, { kind: 'long', until_on: entry[0] });
        }, card.dataset.until === entry[0]));
      });
      chips.appendChild(chip(t('open'), function () { updateItem(card.dataset.issueId, { kind: 'long', until_on: '' }); }));
      pad.appendChild(chips);
      pop.appendChild(pad);
    });
  }

  function menuPopover(card, anchor) {
    var issueId = card.dataset.issueId;
    var location = card.dataset.location;
    var isPeriod = /^\d{4}-\d{2}-\d{2}$/.test(location);
    openPopover(anchor, function (pop) {
      var title = card.querySelector('.tp-card-title, .tp-slim-title');
      pop.appendChild(el('div', 'tp-pop-title', '#' + issueId + ' ' + (title ? title.textContent : '')));
      if (!editable()) {
        pop.appendChild(el('div', 'tp-hint tp-pop-pad', t('readonly')));
        return;
      }
      if (isPeriod) pop.appendChild(item(t('hoursTitle') + ' …', function () { hoursPopover(card); }));
      pop.appendChild(el('div', 'tp-pop-title', t('moveTo')));
      locations().forEach(function (entry) {
        if (entry[0] === location || entry[0] === 'standing') return;
        pop.appendChild(item(entry[1], function () { move(issueId, entry[0], null); }));
      });
      pop.appendChild(el('div', 'tp-pop-sep'));
      if (location === 'standing') {
        pop.appendChild(item(t('normalTask'), function () { move(issueId, board().dataset.current, null); }));
        pop.appendChild(item(t('endStanding'), function () {
          request('POST', urlFor(board().dataset.endStandingUrl, issueId), {}).then(function (data) { afterChange(data); }).catch(showError);
        }));
      } else {
        pop.appendChild(item(t('makeStanding'), function () { move(issueId, 'standing', null); }));
      }
      if (isPeriod) {
        if (card.dataset.kind === 'long') {
          pop.appendChild(item(i18n.noLong || t('normalTask'), function () { updateItem(issueId, { kind: 'normal' }); }));
        } else {
          pop.appendChild(item(t('makeLong'), function () { longPopover(card, anchor); }));
        }
      }
      if (card.dataset.assigned === 'true' && location !== 'pool') {
        pop.appendChild(item(t('toPool'), function () {
          request('POST', urlFor(board().dataset.unassignUrl, issueId), {}).then(function (data) { afterChange(data); }).catch(showError);
        }));
      }
    });
  }

  function carryPopover(card, anchor) {
    openPopover(anchor, function (pop) {
      var pad = el('div', 'tp-pop-pad');
      pad.appendChild(el('strong', null, t('carryTitle')));
      pad.appendChild(item(t('carryLong'), function () { longPopover(card, anchor); }));
      pad.appendChild(item(t('carryKeep'), function () { updateItem(card.dataset.issueId, { carry_ack: anchor.dataset.carries }); }));
      pop.appendChild(pad);
    });
  }

  function absencePopover(button) {
    var workdays = parseInt(button.dataset.workdays, 10) || 5;
    var current = parseInt(button.dataset.days, 10) || 0;
    var options = workdays <= 5 ? [0, 1, 2, 3, 4, 5] : [0, 1, 2, 3, 4, 5, workdays];
    openPopover(button, function (pop) {
      var pad = el('div', 'tp-pop-pad');
      pad.appendChild(el('strong', null, t('absenceTitle')));
      pad.appendChild(el('div', 'tp-hint', t('absenceHint')));
      var chips = el('div', 'tp-chips');
      options.forEach(function (n) {
        var label = n === 0 ? t('none') : (n === workdays ? t('whole') : n + ' ' + t('days'));
        chips.appendChild(chip(label, function () {
          request('PATCH', button.dataset.url, { days: n }).then(function (data) { afterChange(data); }).catch(showError);
        }, n === current));
      });
      pad.appendChild(chips);
      pop.appendChild(pad);
    });
  }

  function settingsPopover(button) {
    var container = document.getElementById('team-planning-board');
    openPopover(button, function (pop) {
      var form = el('form', 'tp-pop-pad');
      form.appendChild(el('strong', null, t('settingsTitle')));
      var lengthLabel = el('label', 'tp-lbl', t('periodLength'));
      var select = el('select');
      select.name = 'weeks';
      [1, 2, 3, 4].forEach(function (n) {
        var option = el('option', null, n === 1 ? t('weekOne') : t('weeksMany').replace(/\d+/, n));
        option.value = n;
        if (String(n) === container.dataset.weeks) option.selected = true;
        select.appendChild(option);
      });
      lengthLabel.appendChild(select);
      form.appendChild(lengthLabel);
      var limitLabel = el('label', 'tp-lbl', t('limitLabel'));
      var limit = el('input');
      limit.type = 'number';
      limit.min = 1;
      limit.max = 99;
      limit.name = 'limit';
      limit.value = container.dataset.limit;
      limitLabel.appendChild(limit);
      form.appendChild(limitLabel);
      form.appendChild(el('div', 'tp-hint', t('limitHint')));
      var save = el('button', 'tp-btn tp-btn-primary tp-btn-sm', t('save'));
      save.type = 'submit';
      form.appendChild(save);
      form.addEventListener('submit', function (event) {
        event.preventDefault();
        request('PATCH', container.dataset.settingsUrl, { weeks: select.value, limit: limit.value })
          .then(function (data) {
            try { sessionStorage.setItem('tp-toast', JSON.stringify(data)); } catch (e) { /* egal */ }
            window.location.reload();
          }).catch(showError);
      });
      pop.appendChild(form);
    });
  }

  // Abhaken: offene Abschluss-Aktionen abfragen; ohne Aktionen direkt
  function check(button, root) {
    var row = button.closest('[data-issue-id]');
    var issueId = row.dataset.issueId;
    var urls = root.dataset;
    if (button.getAttribute('aria-pressed') === 'true') {
      request('POST', urlFor(urls.reopenUrl, issueId), {}).then(function (data) { afterChange(data); }).catch(showError);
      return;
    }
    request('GET', urlFor(urls.doneOptionsUrl, issueId)).then(function (options) {
      var complete = function (actionId) {
        request('POST', urlFor(urls.completeUrl, issueId), { action_id: actionId || '' })
          .then(function (data) { afterChange(data); }).catch(showError);
      };
      if (!options.length) { complete(null); return; }
      openPopover(button, function (pop) {
        pop.appendChild(el('div', 'tp-pop-title', '#' + issueId + ' ' + t('doneTitle')));
        var firstEnabled = true;
        options.forEach(function (option) {
          var body = el('span');
          var name = el('strong', null, option.label);
          body.appendChild(name);
          if (!option.disabled && firstEnabled) { body.appendChild(el('span', 'tp-hint', ' ' + t('enter'))); }
          body.appendChild(el('br'));
          body.appendChild(el('span', 'tp-hint', t('status') + ' ' + option.status + ' · ' + option.assign + (option.comment ? ' · ' + t('withComment') : '')));
          if (option.disabled) { body.appendChild(el('br')); body.appendChild(el('span', 'tp-blocked', option.disabled)); }
          var entry = item(null, function () { complete(option.id); }, { html: body, disabled: !!option.disabled });
          entry.classList.add('tp-done-option');
          pop.appendChild(entry);
          if (!option.disabled) firstEnabled = false;
        });
        pop.appendChild(el('div', 'tp-pop-sep'));
        pop.appendChild(item(t('doneOnly'), function () { complete(null); }));
      });
    }).catch(showError);
  }

  // Neue Aufgabe in einer Spalte: Titel, Enter; bleibt offen
  function openAddForm(button) {
    var template = document.getElementById('tp-add-template');
    if (!template) return;
    var foot = button.closest('.tp-col-foot');
    var location = button.dataset.tpAdd;
    if (location === 'backlog' && boardState.backlog === 'pool') location = 'pool';
    boardState.addOpen = button.dataset.tpAdd;
    var form = template.content.firstElementChild.cloneNode(true);
    button.hidden = true;
    foot.appendChild(form);
    var title = $('.tp-add-title', form);
    var project = $('.tp-add-project', form);
    try { var last = localStorage.getItem('tp-last-project'); if (last) project.value = last; } catch (e) { /* egal */ }
    title.focus();
    var close = function () { boardState.addOpen = null; form.remove(); button.hidden = false; };
    $('[data-tp-add-close]', form).addEventListener('click', close);
    form.addEventListener('keydown', function (event) { if (event.key === 'Escape') close(); });
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      if (!title.value.trim()) { title.focus(); return; }
      try { localStorage.setItem('tp-last-project', project.value); } catch (e) { /* egal */ }
      request('POST', board().dataset.createUrl, { subject: title.value, project_id: project.value, to: location })
        .then(function (data) { afterChange(data); }).catch(showError);
    });
  }

  function onBoardClick(event) {
    var b = board();
    if (!b || !b.contains(event.target)) return;
    var target;
    if ((target = event.target.closest('[data-tp-backlog]'))) {
      boardState.backlog = target.dataset.tpBacklog;
      applyBoardState();
    } else if ((target = event.target.closest('[data-tp-past-nav]'))) {
      // Durch frühere Zeiträume blättern
      boardState.pastOn = target.dataset.tpPastNav;
      boardState.pastOpen = true;
      reloadBoard();
    } else if ((target = event.target.closest('[data-tp-past]'))) {
      boardState.pastOpen = !boardState.pastOpen;
      applyBoardState();
    } else if ((target = event.target.closest('[data-tp-menu]'))) {
      menuPopover(target.closest('.tp-card'), target);
    } else if ((target = event.target.closest('[data-tp-hours]'))) {
      if (editable()) hoursPopover(target.closest('.tp-card'));
    } else if ((target = event.target.closest('[data-tp-carry]'))) {
      if (editable()) carryPopover(target.closest('.tp-card'), target);
    } else if ((target = event.target.closest('[data-tp-check]'))) {
      if (editable()) check(target, b);
    } else if ((target = event.target.closest('[data-tp-absence]'))) {
      if (editable()) absencePopover(target);
    } else if ((target = event.target.closest('[data-tp-add]'))) {
      openAddForm(target);
    }
  }

  function onBoardInput(event) {
    if (event.target.matches('.tp-board .tp-filter-text')) {
      boardState.filterText = event.target.value;
      filterBacklog();
    }
  }

  function onBoardChange(event) {
    if (event.target.matches('.tp-board .tp-filter-project')) {
      boardState.filterProject = event.target.value;
      filterBacklog();
    }
  }

  function onBoardKey(event) {
    var card = event.target.closest && event.target.closest('.tp-board .tp-card');
    if (card && event.target === card && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      menuPopover(card, card);
    }
  }

  // --- Abschluss --------------------------------------------------------------

  function initClose() {
    var form = $('[data-tp-close]');
    if (!form) return;
    var hint = $('[data-tp-missing]', form);
    var submit = form.querySelector('input[type=submit]');
    var update = function () {
      var groups = {};
      $$('input[type=radio][name^="decisions"]', form).forEach(function (radio) {
        groups[radio.name] = groups[radio.name] || radio.checked;
      });
      var missing = Object.keys(groups).filter(function (name) { return !groups[name]; }).length;
      if (hint) hint.textContent = missing ? hint.dataset.template.replace('%{count}', missing) : '';
      if (submit) submit.disabled = missing > 0;
    };
    form.addEventListener('change', update);
    $$('[data-tp-decide-all]', form).forEach(function (button) {
      button.addEventListener('click', function () {
        $$('input[type=radio][value="' + button.dataset.tpDecideAll + '"]', form).forEach(function (radio) { radio.checked = true; });
        update();
      });
    });
    update();
    var timer = $('[data-tp-timer]');
    if (timer) {
      var started = Date.now();
      setInterval(function () {
        var seconds = Math.floor((Date.now() - started) / 1000);
        timer.textContent = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0') + ' min';
        timer.classList.toggle('is-slow', seconds > 300);
      }, 1000);
    }
  }

  // --- Teamrunde --------------------------------------------------------------

  function initRound() {
    var notes = document.getElementById('tp-round-notes');
    if (!notes) return;
    var state = $('[data-tp-notes-state]');
    var timer = null;
    var saved = notes.value;
    var save = function () {
      clearTimeout(timer);
      if (notes.value === saved) return;
      var value = notes.value;
      request('PATCH', notes.dataset.url, { notes: value }).then(function () {
        saved = value;
        if (state) state.textContent = notes.dataset.saved;
      }).catch(showError);
    };
    var later = function () { clearTimeout(timer); timer = setTimeout(save, 600); };
    notes.addEventListener('input', later);
    notes.addEventListener('blur', save);
    // Redmines Werkzeugleiste ändert den Text ohne input-Ereignis
    document.addEventListener('click', function (event) {
      if (event.target.closest('.jstElements')) setTimeout(later, 0);
    });
  }

  // --- Meine Seite -------------------------------------------------------------

  function initWidget(widget) {
    widget.addEventListener('click', function (event) {
      var checkButton = event.target.closest('[data-tp-check]');
      if (checkButton) { check(checkButton, widget); return; }
      var hoursButton = event.target.closest('.tp-wbook [data-hours]');
      if (hoursButton) { book(hoursButton.closest('form'), hoursButton.dataset.hours); }
    });
    widget.addEventListener('submit', function (event) {
      var form = event.target.closest('[data-tp-book]');
      if (!form) return;
      event.preventDefault();
      var input = form.querySelector('input[name=hours]');
      if (!input.value.trim()) { input.focus(); return; }
      book(form, input.value);
    });
    // Redmine setzt beim Laden den Fokus aufs erste Textfeld (defaultFocus);
    // aufklappen nur, wenn die Person selbst klickt oder tippt
    var acted = false;
    ['pointerdown', 'keydown'].forEach(function (type) {
      document.addEventListener(type, function () { acted = true; }, true);
    });
    var expand = function (target) {
      if (!target.matches('.tp-wbook input[name=hours]')) return;
      var more = target.closest('form').querySelector('.tp-wmore');
      if (more) more.hidden = false;
    };
    widget.addEventListener('focusin', function (event) { if (acted) expand(event.target); });
    // Das Feld kann schon den Fokus haben (defaultFocus), dann kommt kein focusin
    widget.addEventListener('pointerdown', function (event) { expand(event.target); });
    widget.addEventListener('input', function (event) { expand(event.target); });
  }

  function book(form, hours) {
    var widget = form.closest('[data-tp-widget]');
    var issueId = form.closest('[data-issue-id]').dataset.issueId;
    var field = function (name) { var node = form.querySelector('[name="' + name + '"]'); return node ? node.value : ''; };
    request('POST', urlFor(widget.dataset.timeUrl, issueId), {
      hours: hours, comments: field('comments'), activity_id: field('activity_id'), spent_on: field('spent_on')
    }).then(function (data) { afterChange(data); }).catch(showError);
  }

  // --- Start -------------------------------------------------------------------

  // Einstellungen: Status-Auswahl nur bei "selbst wählen" bearbeitbar
  function initStatusMode() {
    var box = $('[data-tp-status-mode]');
    if (!box) return;
    box.addEventListener('change', function (event) {
      if (event.target.name !== 'settings[done_status_mode]') return;
      var custom = event.target.value === 'custom';
      $$('.tp-status-list input', box).forEach(function (input) { input.disabled = !custom; });
    });
  }

  function init() {
    loadTexts();
    showStoredToast();
    initStatusMode();
    $$('select[data-navigate]').forEach(function (select) {
      select.addEventListener('change', function () { window.location.href = select.value; });
    });
    if (document.getElementById('team-planning-board')) {
      applyBoardState();
      document.addEventListener('click', onBoardClick);
      document.addEventListener('input', onBoardInput);
      document.addEventListener('change', onBoardChange);
      document.addEventListener('keydown', onBoardKey);
      document.addEventListener('click', onClickCapture, true);
      document.addEventListener('pointerdown', onPointerDown);
      document.addEventListener('pointermove', onPointerMove);
      document.addEventListener('pointerup', onPointerUp);
      var settings = $('[data-tp-popover="settings"]');
      if (settings) settings.addEventListener('click', function () { settingsPopover(settings); });
    }
    initClose();
    initRound();
    $$('[data-tp-widget]').forEach(initWidget);
    window.addEventListener('resize', function () { closePopover(); fitBoard(); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
