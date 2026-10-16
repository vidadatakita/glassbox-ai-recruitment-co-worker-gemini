# Engine 07 run 2, F-09: mail_deliveries.error_message held the raw SMTP text, which names the
# recipient ("550 5.1.1 <a@b>: ..."), and Antrean Kerja showed it to HR PIC during the blind period.
# New rows store a category and the SMTP code only (MailDelivery.failure_summary). This migration
# masks every email address in rows already stored (development data, invented). Data only; no
# schema change. Irreversible on purpose: the addresses must not come back.
class MaskMailDeliveryErrorAddresses < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE mail_deliveries
         SET error_message = regexp_replace(error_message, '[^[:space:]<>"''()\\[\\],;:]+@[^[:space:]<>"''()\\[\\],;:]+', '[alamat disamarkan]', 'g')
       WHERE error_message LIKE '%@%';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
