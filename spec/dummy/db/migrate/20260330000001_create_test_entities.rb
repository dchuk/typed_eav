# frozen_string_literal: true

class CreateTestEntities < ActiveRecord::Migration[7.1]
  def change
    create_table :contacts do |t|
      t.string :name, null: false
      t.string :email
      t.string :tenant_id
      t.timestamps
    end

    create_table :products do |t|
      t.string :title, null: false
      t.decimal :price
      t.timestamps
    end

    create_table :projects do |t|
      t.string :name, null: false
      t.string :tenant_id
      t.string :workspace_id
      t.timestamps
    end
  end
end
