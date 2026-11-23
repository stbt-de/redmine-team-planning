# frozen_string_literal: true

# Persönliche Notizen je Zeitraum (neben dem Rückblick)
class AddNotesToTeamPlanningPeriods < ActiveRecord::Migration[6.1]
  def change
    add_column :team_planning_periods, :notes, :text
  end
end
