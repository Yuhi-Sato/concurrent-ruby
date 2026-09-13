#!/usr/bin/env ruby

# Compare the unchanged MutexSemaphore with the CAS implementation in the same
# process. Use -I to select a locally built C extension, or run on TruffleRuby.
# Example: ruby -Ilib/concurrent-ruby examples/benchmark_semaphore.rb --json results.json
require 'concurrent/atomic/semaphore'
require 'json'
require 'optparse'
require 'time'

options = { warmup: 2.0, time: 0.5, samples: 7, json: nil, filter: nil }
OptionParser.new do |parser|
  parser.on('--warmup SECONDS', Float) { |value| options[:warmup] = value }
  parser.on('--time SECONDS', Float) { |value| options[:time] = value }
  parser.on('--samples COUNT', Integer) { |value| options[:samples] = value }
  parser.on('--json PATH') { |value| options[:json] = value }
  parser.on('--filter REGEXP') { |value| options[:filter] = Regexp.new(value) }
end.parse!
raise ArgumentError, 'warmup, time and samples must be positive' unless
  options.values_at(:warmup, :time, :samples).all? { |value| value > 0 }

SCENARIOS = [
  { name: 'acquire_release', threads: 1, permits: 1, operation: :acquire },
  { name: 'try_acquire_release', threads: 1, permits: 1, operation: :try_acquire },
  { name: 'acquire_block', threads: 1, permits: 1, operation: :block },
  { name: 'failed_try_acquire', threads: 1, permits: 0, operation: :failed },
  { name: 'shared_4_threads', threads: 4, permits: 4, operation: :acquire },
  { name: 'shared_8_threads', threads: 8, permits: 8, operation: :acquire },
  # Thread.pass inside the block gives other threads a chance to exhaust the
  # permits, including on CRuby. It is part of the measured work for both classes.
  { name: 'waiting_8_threads', threads: 8, permits: 1, operation: :yield },
  # Exceed the native range and drain before timing. The CAS implementation
  # deliberately keeps this instance on its mutex fallback even at count 1.
  { name: 'after_large_count', threads: 1, permits: 1, operation: :acquire, promoted: true }
].freeze

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def measure(implementation, scenario, iterations)
  semaphore = implementation.new(scenario[:permits])
  if scenario[:promoted]
    semaphore = implementation.new(Concurrent::Utility::NativeInteger::MAX_VALUE)
    semaphore.release
    semaphore.drain_permits
    semaphore.release(scenario[:permits])
  end
  ready = Queue.new
  start = Queue.new
  workers = []
  begin
    scenario[:threads].times do
      workers << Thread.new do
        ready << true
        start.pop
        case scenario[:operation]
        when :acquire
          iterations.times { semaphore.acquire; semaphore.release }
        when :try_acquire
          iterations.times do
            raise 'unexpected acquisition failure' unless semaphore.try_acquire
            semaphore.release
          end
        when :block
          iterations.times { semaphore.acquire { nil } }
        when :failed
          iterations.times { raise 'unexpected acquisition' if semaphore.try_acquire }
        when :yield
          iterations.times { semaphore.acquire { Thread.pass } }
        end
      end
    end
    workers.size.times { ready.pop }
    started = clock
    workers.size.times { start << true }
    workers.each do |worker|
      raise 'worker did not finish within 60 seconds' unless worker.join(60)
      worker.value
    end
    elapsed = clock - started
    raise 'permit count changed' unless semaphore.available_permits == scenario[:permits]
    elapsed
  ensure
    workers.each { |worker| worker.kill if worker.alive? }
    workers.each(&:join)
  end
end

def median(values)
  sorted = values.sort
  middle = sorted.size / 2
  sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

implementations = [Concurrent::MutexSemaphore, Concurrent::AtomicSemaphore]
report = {
  timestamp: Time.now.utc.iso8601,
  ruby: RUBY_DESCRIPTION,
  platform: RUBY_PLATFORM,
  c_extensions: !!Concurrent.c_extensions_loaded?,
  atomic_fixnum: Concurrent::AtomicFixnum.superclass.name,
  public_semaphore: Concurrent::Semaphore.superclass.name,
  yjit: defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false,
  options: options.reject { |key, _| [:json, :filter].include?(key) },
  scenarios: []
}
$stdout.sync = true
puts report.reject { |key, _| key == :scenarios }.to_json
puts 'Throughput is completed operations/second; a successful operation includes release.'
puts format('%-28s %14s %14s %10s', 'Scenario', 'Mutex ops/s', 'CAS ops/s', 'CAS/Mutex')

SCENARIOS.each do |scenario|
  next if options[:filter] && !options[:filter].match(scenario[:name])
  iterations = {}
  implementations.each do |implementation|
    count = 10_000
    started = clock
    begin
      elapsed = measure(implementation, scenario, count)
      # Calibrate outside the samples, then keep each implementation's operation
      # count fixed. The same workload runs for roughly --time seconds per sample.
      count = [[(count * options[:time] / elapsed).to_i, 1].max, 50_000_000].min
    end while clock - started < options[:warmup]
    iterations[implementation] = count
  end

  samples = Hash[implementations.map { |implementation| [implementation, []] }]
  options[:samples].times do |round|
    # Alternate order to reduce systematic thermal/scheduling bias.
    order = round.even? ? implementations : implementations.reverse
    order.each do |implementation|
      GC.start
      count = iterations.fetch(implementation)
      elapsed = measure(implementation, scenario, count)
      operations = count * scenario[:threads]
      samples[implementation] << { operations: operations, seconds: elapsed,
                                   ops_per_second: operations / elapsed }
    end
  end

  results = implementations.map do |implementation|
    rates = samples.fetch(implementation).map { |sample| sample[:ops_per_second] }
    { implementation: implementation.name, median_ops_per_second: median(rates),
      min_ops_per_second: rates.min, max_ops_per_second: rates.max,
      samples: samples.fetch(implementation) }
  end
  ratio = results[1][:median_ops_per_second] / results[0][:median_ops_per_second]
  report[:scenarios] << scenario.merge(results: results, cas_over_mutex: ratio)
  puts format('%-28s %14.0f %14.0f %9.2fx', scenario[:name],
              results[0][:median_ops_per_second], results[1][:median_ops_per_second], ratio)
end

File.write(options[:json], JSON.pretty_generate(report) + "\n") if options[:json]
