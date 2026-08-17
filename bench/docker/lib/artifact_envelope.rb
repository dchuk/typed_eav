# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"

module TypedEAVBenchmark
  module ArtifactEnvelope
    module_function

    def build(status:, task:, run_id:, payload:, diagnostics: {})
      raise ArgumentError, "status must be accepted or rejected" unless %w[accepted rejected].include?(status)

      assert_acyclic!(payload)
      copied = JSON.parse(JSON.generate(payload))
      {
        "schema_version" => 1, "status" => status, "task" => task, "run_id" => run_id,
        "payload" => copied, "diagnostics" => JSON.parse(JSON.generate(diagnostics)),
        "payload_sha256" => Digest::SHA256.hexdigest(JSON.generate(copied))
      }
    end

    def write!(root:, envelope:)
      FileUtils.mkdir_p(root)
      accepted = File.join(root, "accepted.json")
      rejected = File.join(root, "rejected.json")
      destination = envelope.fetch("status") == "accepted" ? accepted : rejected
      other = destination == accepted ? rejected : accepted
      raise "accepted and rejected artifacts are exclusive" if File.exist?(other)

      temporary = "#{destination}.tmp-#{Process.pid}"
      File.write(temporary, "#{JSON.pretty_generate(envelope)}\n")
      File.rename(temporary, destination)
      destination
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def assert_acyclic!(value, active = {})
      return unless value.is_a?(Hash) || value.is_a?(Array)

      id = value.object_id
      raise ArgumentError, "cyclic artifact payload" if active[id]

      active[id] = true
      value.each { |entry| assert_acyclic!(entry.is_a?(Array) && value.is_a?(Hash) ? entry.last : entry, active) }
      active.delete(id)
    end
  end
end
