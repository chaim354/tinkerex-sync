# frozen_string_literal: true

require "test_helper"
require "ripper"

# THE HOST-BOUNDARY GUARDS, LIVING WHERE THE CODE THEY GUARD LIVES.
#
# These two tests were written in the tinkerex monorepo (test/architecture_invariants_test.rb)
# while this engine was a directory inside it, and they scanned that directory. The 2026-08-20
# extraction moved the code out and left them scanning NOTHING -- one of them went on passing over
# an empty file list, which is precisely the "green suite over something that never worked" shape
# the monorepo's own CLAUDE.md names as its dominant failure mode. So they moved with the code
# rather than being deleted, and the monorepo's copies were removed rather than left hollow.
#
# BOOTING IS NOT A SUBSTITUTE FOR THEM, which is the reason they exist at all here. test/dummy
# proves the engine LOADS with no maker application present -- but a stray `Maker::Foo` inside a
# rarely-taken branch loads perfectly well and raises only when that branch runs. A static scan
# catches the reference; the dummy catches the wiring. Neither subsumes the other.
class ArchitectureTest < ActiveSupport::TestCase
  ROOT = Pathname.new(File.expand_path("..", __dir__))

  # Ripper, not grep: this tree is full of prose that names Maker:: and FileLayer in comments, and
  # a comment naming a constant is not a reference to it. A regex cannot tell those apart; the
  # lexer answers exactly the question being asked.
  def self.engine_files
    Dir.glob(ROOT.join("{app,lib}", "**", "*.rb")) + Dir.glob(ROOT.join("{app,lib}", "**", "*.rake"))
  end

  # `Maker` only counts when followed by `::` -- a bare `Maker` is not a namespace reach, and the
  # word appears in prose throughout.
  def maker_references(file)
    Ripper.lex(File.read(file)).each_cons(2).filter_map do |(pos, type, str, _), (_, t2, s2, _)|
      pos.first if type == :on_const && str == "Maker" && t2 == :on_op && s2 == "::"
    end
  end

  def host_constant_references(file)
    Ripper.lex(File.read(file)).filter_map do |(pos, type, str, _)|
      pos.first if type == :on_const && HOST_CONSTANTS.include?(str)
    end
  end

  # What a HOST owns and a bare mount cannot resolve. Deliberately not scoped to the references
  # that happen to exist today: the monorepo's version of this list started at two names and missed
  # a third, because a guard scoped to the violations you already know about only ever confirms
  # what you already know.
  HOST_CONSTANTS = %w[FileLayer LibraryCapabilities Maker ApplicationController].freeze

  # THE ONE SANCTIONED INVERSE. This engine SHIPS a FileLayer port adapter; the host ships the
  # factory that chooses it. So `module FileLayer` at the top of this file is the engine reopening
  # a namespace it adapts, not a reach into a host that must already be loaded. Excluded BY NAME
  # rather than by loosening the detector, which would just as easily hide a real new violation
  # landing in the same file.
  HOST_REFERENCE_EXCEPTIONS = %w[app/services/file_layer/chunk.rb].freeze

  test "no engine file reaches into the maker layer" do
    offenders = self.class.engine_files
                    .select { |f| maker_references(f).any? }
                    .map { |f| Pathname.new(f).relative_path_from(ROOT).to_s }.sort

    assert_empty offenders,
                 "engine code naming Maker:: -- the host subscribes through Sync::Hooks, the " \
                 "engine never calls into it: #{offenders}"
  end

  test "no engine file names a host constant, so a bare mount can load it" do
    hits = self.class.engine_files.filter_map { |f|
      rel = Pathname.new(f).relative_path_from(ROOT).to_s
      [ rel, host_constant_references(f) ] if host_constant_references(f).any?
    }.to_h

    offenders = hits.keys.sort - HOST_REFERENCE_EXCEPTIONS
    assert_empty offenders,
                 "engine code naming a host constant (#{HOST_CONSTANTS.join(', ')}), none of " \
                 "which a bare mount can autoload. Ask Sync.capability_available? / " \
                 "Sync.capability_unavailable_message instead: #{offenders}"

    # The exception must stay LIVE, not linger as dead weight hiding nothing. If chunk.rb ever
    # stops naming FileLayer (a rewrite, a rename), this reports the stale entry rather than
    # leaving a future reader to wonder whether it still means anything.
    stale = HOST_REFERENCE_EXCEPTIONS - hits.keys
    assert_empty stale,
                 "HOST_REFERENCE_EXCEPTIONS names a file that no longer references any of " \
                 "#{HOST_CONSTANTS.join(', ')} -- remove it: #{stale}"
  end

  test "the scans actually have files to scan" do
    # Both tests above are `assert_empty offenders`, which an empty file list satisfies perfectly.
    # That is exactly how they died in the monorepo when the code moved out from under them, so
    # the file list is asserted here rather than assumed.
    assert_operator self.class.engine_files.size, :>, 50,
                    "engine_files found #{self.class.engine_files.size} files -- the guards above " \
                    "cannot fail if there is nothing to scan"
  end
end
