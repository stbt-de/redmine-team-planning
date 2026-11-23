# frozen_string_literal: true

# Ein Planungszeitraum einer Person (Beginn Montag, Länge in Wochen)
class TeamPlanningPeriod < ApplicationRecord
  belongs_to :user
  has_many :items, -> { order(:position, :id) }, class_name: 'TeamPlanningItem', foreign_key: :period_id,
                                                  inverse_of: :period, dependent: :destroy

  validates :starts_on, presence: true, uniqueness: { scope: :user_id }
  validates :weeks, numericality: { only_integer: true, greater_than: 0, less_than: 5 }
  validates :absence_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :open, -> { where(closed_at: nil) }
  scope :closed, -> { where.not(closed_at: nil) }

  def ends_on
    starts_on + (7 * weeks) - 1
  end

  # Arbeitstage Montag bis Freitag
  def workdays
    5 * weeks
  end

  def last_workday
    starts_on + (7 * (weeks - 1)) + 4
  end

  def include?(date)
    date >= starts_on && date <= ends_on
  end

  def closed?
    closed_at.present?
  end

  def week_numbers
    (0...weeks).map { |n| (starts_on + (7 * n)).cweek }
  end

  # "KW 48" oder "KW 48–49"
  def label
    numbers = week_numbers
    numbers.size == 1 ? "KW #{numbers.first}" : "KW #{numbers.first}–#{numbers.last}"
  end

  def range_label
    "#{starts_on.strftime('%-d.%-m.')}–#{last_workday.strftime('%-d.%-m.')}"
  end
end
