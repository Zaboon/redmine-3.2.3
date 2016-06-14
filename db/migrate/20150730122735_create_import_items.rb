class CreateImportItems < ActiveRecord::Migration
  def change
    create_table :import_items do |t|
      t.integer :import_id, :null => false
      t.integer :position, :null => false
      t.integer :obj_id
      t.text :message
    end
  end
end
