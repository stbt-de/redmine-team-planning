# frozen_string_literal: true

class CreateTeamPlanningTables < ActiveRecord::Migration[6.1]
  def change
    # Ein Zeitraum einer Person: Beginn (Montag) und Länge in Wochen
    create_table :team_planning_periods do |t|
      t.integer :user_id, null: false
      t.date :starts_on, null: false
      t.integer :weeks, null: false, default: 1
      t.integer :absence_days, null: false, default: 0
      t.string :focus
      t.text :review_good
      t.text :review_bad
      t.text :review_change
      t.datetime :closed_at
      t.timestamps
    end
    add_index :team_planning_periods, %i[user_id starts_on], unique: true

    # Ein Ticket in einem Zeitraum
    create_table :team_planning_items do |t|
      t.integer :period_id, null: false
      t.integer :issue_id, null: false
      t.integer :position, null: false, default: 0
      t.string :kind, null: false, default: 'normal' # normal, long
      t.date :until_on                                 # Zielwoche eines Langläufers
      t.decimal :planned_hours, precision: 6, scale: 2
      t.string :origin, null: false, default: 'planned' # planned, carried, unplanned
      t.string :result                                  # done, carried, backlog, closed
      t.boolean :done, null: false, default: false
      # Bis zu dieser Zahl an Überträgen fragt das Board nicht mehr nach ("passt so")
      t.integer :carry_ack, null: false, default: 0
      # Vor einer Abschluss-Aktion: zum Rückgängigmachen
      t.integer :previous_status_id
      t.integer :previous_assigned_to_id
      t.timestamps
    end
    add_index :team_planning_items, %i[period_id issue_id], unique: true
    add_index :team_planning_items, :issue_id

    # Dauerthemen einer Person: laufen jede Woche mit
    create_table :team_planning_standings do |t|
      t.integer :user_id, null: false
      t.integer :issue_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :team_planning_standings, %i[user_id issue_id], unique: true

    # "Später": vorgemerkt, ohne festen Zeitraum
    create_table :team_planning_later_items do |t|
      t.integer :user_id, null: false
      t.integer :issue_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :team_planning_later_items, %i[user_id issue_id], unique: true

    # Einstellungen je Person
    create_table :team_planning_user_settings do |t|
      t.integer :user_id, null: false
      t.integer :weeks, null: false, default: 1
      t.integer :item_limit, null: false, default: 6
      t.timestamps
    end
    add_index :team_planning_user_settings, :user_id, unique: true

    # Teamrunde: Notizen je Termin
    create_table :team_planning_rounds do |t|
      t.date :held_on, null: false
      t.text :notes
      t.datetime :reminded_at
      t.timestamps
    end
    add_index :team_planning_rounds, :held_on, unique: true
  end
end
