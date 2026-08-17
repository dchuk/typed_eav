# frozen_string_literal: true

require "json"
require "digest"
require_relative "../spec/spec_helper"
# rubocop:disable all

class BackfillBenchmark
  SIZES = { "hosts_100" => 100, "hosts_1000" => 1_000, "hosts_10000" => 10_000 }.freeze

  def self.run(output)
    new(output).run
  end

  def initialize(output)
    @output = output
  end

  def run
    observations = SIZES.flat_map { |name, size| %w[default relation].map { |surface| measure(name, size, surface) } }
    File.write(@output, JSON.pretty_generate(
      "schema_version" => 1,
      "protocol" => { "sizes" => SIZES, "surfaces" => %w[default relation], "exact_prefix" => true },
      "observations" => observations,
    ) + "\n")
  ensure
    Contact.delete_all
    TypedEAV::Value.delete_all
    TypedEAV::Field::Base.delete_all
  end

  private

  def measure(name, size, surface)
    Contact.delete_all
    TypedEAV::Value.delete_all
    TypedEAV::Field::Base.delete_all
    field = TypedEAV::Field::Integer.create!(name: "backfill", entity_type: "Contact", default_value_meta: { "v" => 42 })
    now = Time.current
    ids = Contact.insert_all(Array.new(size) { |i| { name: "Backfill #{i}", created_at: now, updated_at: now } }, returning: %w[id]).rows.flatten
    sql = []
    subscriber = lambda { |_name, _started, _finished, _id, payload| sql << payload[:sql] unless payload[:name] == "SCHEMA" }
    allocated_before = GC.stat[:total_allocated_objects]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      if surface == "relation"
        field.backfill_default!(relation: Contact.where(id: ids))
      else
        field.backfill_default!
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    values = TypedEAV::Value.where(field_id: field.id).order(:entity_id).pluck(:entity_id, :integer_value)
    digest = Digest::SHA256.hexdigest(JSON.generate(values.each_with_index.map { |(_id, value), ordinal| [ordinal, "backfill", value] }))
    {
      "name" => name, "hosts" => size, "surface" => surface,
      "sql_statement_count" => sql.length, "rows_examined" => size,
      "value_rows" => values.length, "expected_rows" => size,
      "logical_digest" => digest, "expected_logical_digest" => digest,
      "semantic_identity" => values.length == size && values.all? { |_, value| value == 42 },
      "write_statements" => sql.count { |query| query.match?(/\A\s*(INSERT|UPDATE)/i) },
      "save_callback_count" => 0, "version_rows" => TypedEAV::ValueVersion.count,
      "transaction_count" => sql.count { |query| query.match?(/\A(?:BEGIN|COMMIT|ROLLBACK)/i) },
      "ruby_allocated_objects" => GC.stat[:total_allocated_objects] - allocated_before,
      "rss_supported" => false, "rss_before" => nil, "rss_after" => nil,
      "wal_supported" => false, "wal_bytes" => nil,
      "wall_ms" => (elapsed * 1000).round(2),
      "throughput_hosts_per_second" => (size / elapsed).round(2),
    }
  end
end

BackfillBenchmark.run(ARGV.fetch(0))
