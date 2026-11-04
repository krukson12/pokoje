"""Excel "harmonogram" -> SQL for pokoje_events (one year, sheets "<year>" and "Komunie <year>").

Usage: python import_harmonogram.py file.xlsx 2026 out.sql   (needs openpyxl)
Then:  REF=wkzaebbfhytuauioqjqw ~/terminy/sql.sh out.sql
The output holds client data: keep it out of the repo. Re-running replaces that year's import,
but refuses once anything from it was changed in the app.
"""
import datetime
import json
import re
import sys

import openpyxl

EVENT_COLS = ['Jaka uroczystość', 'Nazwisko', 'tel', 'liczba osób', 'czy zadatek', 'czy jest umowa podpisana']
# The communion sheet has no header over the name column; later sheets call it "nazwisko".
COMMUNION_COLS = ['nazwisko', 'tel', 'liczba osób', 'czy kolacja', 'czy umowa', 'zadatek']
DATE_RE = re.compile(r'(\d{2})\.(\d{2})\.(\d{4})')


def text(v):
    if v is None:
        return ''
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if isinstance(v, datetime.datetime):
        v = v.strftime('%d.%m.%Y')
    return re.sub(r'\s+', ' ', str(v)).strip()


def cut_cancelled(cells):
    """Cancelled bookings sit to the right of a 'rezygnacja' cell: drop them."""
    for i, v in enumerate(cells):
        if text(v).lower().startswith('rezygnacja'):
            return cells[:i], True
    return cells, False


def record(cols, values, notes):
    data = {k: text(v) for k, v in zip(cols, values) if text(v)}
    if not data:
        return None
    inne = ' · '.join(t for t in map(text, notes) if t)
    if inne:
        data['inne'] = inne
    return data


def events(ws, year):
    out, cancelled = [], 0
    for n, row in enumerate(ws.iter_rows(values_only=True), 1):
        row = list(row) + [None] * 9
        if not isinstance(row[1], datetime.datetime) or row[1].year != year:
            continue
        cells, cut = cut_cancelled(row)
        cancelled += cut
        # Columns 2-7 are the headed ones; "inne" (8) and the unheaded ones after it are notes.
        data = record(EVENT_COLS, cells[2:8], cells[8:])
        if data:  # rows with only a hall note ("oranżeria", "wolna sala") mark free halls, not events
            out.append(('impreza', row[1].date(), data, n))
    return out, cancelled


def communions(ws, year):
    # Two blocks side by side: (slot, name..zadatek, notes) at columns 1-10 and 11-23.
    blocks = [(1, 2, 8, 11), (11, 12, 18, 24)]
    day = [None, None]
    out, cancelled = [], 0
    for n, row in enumerate(ws.iter_rows(values_only=True), 1):
        row = list(row) + [None] * 40
        row, cut = cut_cancelled(row)
        cancelled += cut
        row += [None] * 40
        for b, (slot, first, notes, end) in enumerate(blocks):
            m = DATE_RE.search(text(row[first]))
            if m:
                d = datetime.date(int(m[3]), int(m[2]), int(m[1]))
                day[b] = d if d.year == year else None
                continue
            if not day[b]:
                continue
            # Bookings have a slot number (1, 2, ...); other lines are headers like "BOŻE CIAŁO".
            data = record(COMMUNION_COLS, row[first:first + 6], row[notes:end]) if text(row[slot]).isdigit() else None
            if data:
                # Some rows have the phone one column too far right, under "czy kolacja".
                if 'tel' not in data and re.fullmatch(r'[\d ;,]{9,}', data.get('czy kolacja', '')):
                    data['tel'] = data.pop('czy kolacja')
                out.append(('komunia', day[b], data, n * 2 + b))
            elif not text(row[slot]) and any(map(text, row[notes:end])):
                # A note on its own line belongs to the booking above it in the same block.
                prev = next((e for e in reversed(out) if e[1] == day[b] and e[3] % 2 == b), None)
                if prev:
                    extra = ' · '.join(t for t in map(text, row[notes:end]) if t)
                    prev[2]['inne'] = (prev[2].get('inne', '') + ' · ' + extra).strip(' ·')
    return out, cancelled


def main(path, year, out_path):
    year = int(year)
    wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
    ev, c1 = events(wb[str(year)], year)
    co, c2 = communions(wb[f'Komunie {year}'], year)
    rows = ev + co
    source = f'excel-{year}'
    # Re-importing deletes that year's rows (and with them their attachments), so refuse when
    # anything from the import was edited, deleted or given files in the app since.
    guard = f"""do $$ begin
  if exists (select 1 from pokoje_events e where e.source = '{source}'
             and (e.updated_by is distinct from 'import excel' or exists (select 1 from pokoje_files f where f.event_id = e.id)))
     or exists (select 1 from pokoje_log l where l.tbl = 'pokoje_events' and l.old ->> 'source' = '{source}' and l.new = '{{}}')
  then raise exception 'Import przerwany: imprezy z tego importu były zmieniane, usuwane albo mają pliki w aplikacji.';
  end if;
end $$;"""
    sql = [guard, f"delete from pokoje_events where source = '{source}';"]
    for kind, day, data, sort in rows:
        sql.append("insert into pokoje_events (day, kind, data, sort, source, updated_by) values "
                   f"('{day}', '{kind}', $j${json.dumps(data, ensure_ascii=False)}$j$::jsonb, {sort}, '{source}', 'import excel');")
    with open(out_path, 'w') as f:
        f.write('begin;\n' + '\n'.join(sql) + '\ncommit;\n')
    print(f'imprezy: {len(ev)}, komunie: {len(co)}, skipped cancelled: {c1 + c2} -> {out_path}')
    return rows


if __name__ == '__main__':
    main(*sys.argv[1:4])
