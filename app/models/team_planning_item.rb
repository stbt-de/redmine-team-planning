# frozen_string_literal: true

# Ein Ticket in einem Zeitraum einer Person
class TeamPlanningItem < ApplicationRecord
  KINDS = %w[normal long].freeze
  ORIGINS = %w[planned carried unplanned].freeze
  RESULTS = %w[done carried backlog closed].freeze

  belongs_to :period, class_name: 'TeamPlanningPeriod', inverse_of: :items
  belongs_to :issue

  validates :kind, inclusion: { in: KINDS }
  validates :origin, inclusion: { in: ORIGINS }
  validates :result, inclusion: { in: RESULTS }, allow_nil: true
  validates :issue_id, uniqueness: { scope: :period_id }
  validates :planned_hours, numericality: { greater_than: 0, less_than_or_equal_to: 1000 }, allow_nil: true

  def long?
    kind == 'long'
  end
end
