# Redmine plugin directory – Team Planning

Fields for the entry on https://www.redmine.org/plugins (*Register a new plugin*).
Text fields use Redmine's Textile formatting.

## Plugin Name

Team Planning

## Identifier

redmine_team_planning

## Description

Plan in periods, review, and meet as a team – a board in Redmine instead of a planning spreadsheet, wiki page or "planning week" field. Everyone plans their own period (one to four weeks), closes it with a short review, and the team meeting shows all plans side by side. Issues stay Redmine issues, with Redmine's permissions and workflows.

* *Board* – backlog (or the pool of unassigned issues), the current period, the next three and *Later*; drag issues between them. The number of issues per period is the key figure, with a limit that warns but never blocks; hours are optional.
* *Ongoing topics and long-running issues* – recurring work runs along every week without counting against the limit; long-running issues move on without asking. Absence lowers the limit.
* *Ticking off with completion actions* – e.g. _Invoice_: status _For Billing_, assigned to whoever has the role _Billing_ in the project, with a comment "Done in week 48, 3.5 h logged". Respects the workflow; undo restores status and assignee.
* *Closing a period* – summary, one decision per open issue (next period, backlog, close), a short review and the focus for the next period.
* *Closings* – who has closed their period this week, who is behind, whose longer period runs on.
* *Team meeting* – all plans by person or by project, meeting notes, an email reminder for everyone not prepared yet.
* *My page block "Planning"* – tick off and log time (+0.5, +1, +2 or any number) without opening the board.
* Permissions for own planning, viewing and editing others' plans; one rake task takes over a "planning week" list field.

Works with any theme; styled for the "Klar theme":https://github.com/stbt-de/redmine-klar-theme. English and German.

## Homepage

https://github.com/stbt-de/redmine-team-planning

## Code repository

https://github.com/stbt-de/redmine-team-planning

## Thumbnail

`docs/thumbnail.png` (100 × 100 px; source: `docs/thumbnail.svg`)

## Installation notes

The folder in @plugins/@ must be named <code>redmine_team_planning</code>.

<pre>
cd /path/to/redmine/plugins
git clone https://github.com/stbt-de/redmine-team-planning.git redmine_team_planning
cd ..
bundle exec rake redmine:plugins:migrate NAME=redmine_team_planning RAILS_ENV=production
</pre>

Or unpack the release zip from "GitHub releases":https://github.com/stbt-de/redmine-team-planning/releases into @plugins/@ and run the migration.

Restart Redmine. Then grant the permissions (_Administration → Roles and permissions_, section _Project_) and set up the completion actions (_Administration → Plugins → Team Planning → Configure_). The README has a step-by-step setup guide, including the hourly cron job for the meeting reminder.

## Plugin version

0.1.5

## Redmine compatibility

Tick: **7.0.x**, **6.1.x**, **6.0.x** (tested; see README → *Installation*).
Not 7.1.x until it has been tested.

## Updating this entry

On a new release: on redmine.org open the plugin → *Add a version*, enter the version
and the compatible Redmine versions. Change name, description or installation notes
here first, then copy them over.
