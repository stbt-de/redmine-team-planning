# frozen_string_literal: true

# Dauerthema einer Person: läuft jede Woche mit, zählt nicht gegen die Obergrenze
class TeamPlanningStanding < ApplicationRecord
  belongs_to :user
  belongs_to :issue

  validates :issue_id, uniqueness: { scope: :user_id }
end
