# frozen_string_literal: true

namespace :redmine do
  namespace :team_planning do
    # Erinnerung vor der Teamrunde. Stündlich per Cron aufrufen; verschickt
    # einmal je Runde, sobald der eingestellte Zeitpunkt erreicht ist.
    desc 'Team Planning: Erinnerung vor der Teamrunde verschicken'
    task send_reminders: :environment do
      count = TeamPlanningMailer.deliver_reminders
      puts "Team Planning: #{count} Erinnerung(en) verschickt" if count.positive?
    end

    # Übernimmt das Listenfeld "Planning Week" (Backlog, KW 01 … KW 53).
    # Aufruf: rake redmine:team_planning:import_planning_week FIELD="Planning Week" YEAR=2026
    desc 'Team Planning: Werte aus dem Feld "Planning Week" übernehmen'
    task import_planning_week: :environment do
      field = IssueCustomField.find_by!(name: ENV.fetch('FIELD', 'Planning Week'))
      year = ENV.fetch('YEAR', Date.current.year).to_i
      result = RedmineTeamPlanning::Import.new(field, year: year).call
      puts "Team Planning: #{result[:planned]} eingeplant, #{result[:carried]} in den laufenden Zeitraum übertragen, " \
           "#{result[:skipped]} ohne Zuweisung übersprungen"
    end
  end
end
