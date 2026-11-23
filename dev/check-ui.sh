#!/usr/bin/env bash
# Browser-Durchlauf (dev/check-ui.mjs) gegen die lokale Redmine-Instanz aus
# redmine-theme (Container redmine-klar-theme, SQLite). Sichert die Datenbank
# vorher und setzt sie danach zurück, auch bei Fehlern.
# Braucht: Playwright (npm install im Plugin-Ordner) und Benutzer "admin"/"admin".
set -euo pipefail
container="${CONTAINER:-redmine-klar-theme}"
base="${BASE_URL:-http://localhost:3080}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp -d)"

wait_ready() { for _ in $(seq 1 90); do curl -fs "$base/login" >/dev/null && return 0; sleep 2; done; echo "Redmine antwortet nicht" >&2; exit 1; }
restore() {
  docker stop "$container" >/dev/null
  docker run --rm --volumes-from "$container" alpine:3.20 sh -c 'cd /usr/src/redmine/sqlite && rm -f redmine.db redmine.db-wal redmine.db-shm && cp -a tp-check-backup/redmine.db* . && rm -rf tp-check-backup'
  docker start "$container" >/dev/null
  wait_ready
  echo "Datenbank zurückgesetzt."
}

docker stop "$container" >/dev/null
docker run --rm --volumes-from "$container" alpine:3.20 sh -c 'cd /usr/src/redmine/sqlite && rm -rf tp-check-backup && mkdir tp-check-backup && cp -a redmine.db* tp-check-backup/'
docker start "$container" >/dev/null
trap restore EXIT
wait_ready

# Voraussetzungen: Rechte, ein Benutzer ohne Bearbeitungsrecht, zwei Abschluss-Aktionen
docker exec "$container" bin/rails runner -e production '
Role.givable.each { |r| r.add_permission!(:use_team_planning, :view_others_team_planning) }
Role.givable.first.add_permission!(:edit_others_team_planning)
member = User.active.where(admin: false).detect { |u| u.roles.none? { |r| r.has_permission?(:edit_others_team_planning) } }
member.password = member.password_confirmation = "tp-check-1234"; member.save!
File.write("/tmp/tp-check-user", member.login)
closed = IssueStatus.where(is_closed: true).sorted.first
open_last = IssueStatus.where(is_closed: false).sorted.last
Setting.plugin_redmine_team_planning = RedmineTeamPlanning::Settings::DEFAULTS.merge("done_actions" => [
  { "id" => "bill", "label" => "Abrechnen", "status_id" => open_last.id, "assign" => "role:#{Role.givable.first.id}", "comment" => "1", "project_ids" => [] },
  { "id" => "done", "label" => "Fertig, ohne extra Rechnung", "status_id" => closed.id, "assign" => "keep", "comment" => "0", "project_ids" => [] }])
' 2>&1 | grep -v '^Ignoring' || true
member="$(docker exec "$container" cat /tmp/tp-check-user)"

MEMBER_LOGIN="$member" node "$root/dev/check-ui.mjs" "$out" "$base"
echo "Bildschirmfotos: $out"
