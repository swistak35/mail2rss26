# frozen_string_literal: true

require "optparse"

module Mail2rss26
  # Argument plumbing for the two commands. Both are stubs until Phases 2-4;
  # what is real here is the parsing, so the shape of the interface is fixed
  # before anything depends on it.
  module CLI
    # The full exit-code contract is written down in Phase 4, once `ingest`
    # actually does something — it is the interface with OpenSMTPD, not a
    # detail. Until then: 0 nothing ever, 2 for a caller mistake, 1 for
    # "this does not exist yet".
    EX_OK = 0
    EX_NOT_IMPLEMENTED = 1
    EX_USAGE = 2

    COMMANDS = %w[ingest render].freeze

    BANNER = <<~USAGE
      Usage: mail2rss26 <command> [options]

      Commands:
          ingest    Read one message on stdin and file it under a feed
          render    Rebuild a feed's atom.xml from the messages on disk

      Run `mail2rss26 <command> --help` for the options of a command.
    USAGE

    module_function

    # Returns an exit code rather than calling exit, so the tests can drive it.
    def run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      command = argv.first

      case command
      when nil, "-h", "--help", "help"
        stdout.puts BANNER
        command.nil? ? EX_USAGE : EX_OK
      when "--version"
        stdout.puts "mail2rss26 #{VERSION}"
        EX_OK
      when "ingest"
        ingest(parse_ingest(argv.drop(1)), stdin: stdin, stderr: stderr)
      when "render"
        render(parse_render(argv.drop(1)), stderr: stderr)
      else
        stderr.puts "mail2rss26: unknown command #{command.inspect}"
        stderr.puts BANNER
        EX_USAGE
      end
    rescue OptionParser::ParseError, ArgumentError => e
      # A malformed invocation is the operator's bug, not a delivery failure —
      # it is worth telling apart from the codes `ingest` returns.
      stderr.puts "mail2rss26: #{e.message}"
      EX_USAGE
    end

    def parse_ingest(args)
      options = { state_dir: DEFAULT_STATE_DIR }

      parser = OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 ingest --recipient ADDRESS [options] < message.eml"
        o.on("--recipient ADDRESS", "Envelope recipient the message was delivered to") do |v|
          options[:recipient] = v
        end
        o.on("--state-dir DIR", "Where feeds and messages live (default: #{DEFAULT_STATE_DIR})") do |v|
          options[:state_dir] = v
        end
      end
      parser.parse!(args)

      raise ArgumentError, "ingest: --recipient is required" if options[:recipient].nil?
      raise ArgumentError, "ingest: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    def parse_render(args)
      options = { state_dir: DEFAULT_STATE_DIR }

      parser = OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 render --feed NAME [options]"
        o.on("--feed NAME", "Feed to re-render; omit to re-render every feed") do |v|
          options[:feed] = v
        end
        o.on("--state-dir DIR", "Where feeds and messages live (default: #{DEFAULT_STATE_DIR})") do |v|
          options[:state_dir] = v
        end
      end
      parser.parse!(args)

      raise ArgumentError, "render: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    # Phase 4.
    def ingest(_options, stdin: $stdin, stderr: $stderr)
      stderr.puts "mail2rss26: ingest is not implemented yet"
      EX_NOT_IMPLEMENTED
    end

    # Phase 3.
    def render(_options, stderr: $stderr)
      stderr.puts "mail2rss26: render is not implemented yet"
      EX_NOT_IMPLEMENTED
    end
  end
end
