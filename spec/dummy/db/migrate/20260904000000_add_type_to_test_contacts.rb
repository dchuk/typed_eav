# frozen_string_literal: true

class AddTypeToTestContacts < ActiveRecord::Migration[7.1]
  def change
    add_column :contacts, :type, :string
  end
end
