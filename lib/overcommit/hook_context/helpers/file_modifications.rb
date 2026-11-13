# frozen_string_literal: true

module Overcommit::HookContext
  module Helpers
    # This module contains methods for determining what files were changed and on what unique line
    # numbers did the change occur.
    module FileModifications
      DIFF_BASE_MUTEX = Mutex.new
      private_constant :DIFF_BASE_MUTEX

      # Returns whether this hook run was triggered by `git commit --amend`
      def amendment?
        return @amendment unless @amendment.nil?

        cmd = Overcommit::Utils.parent_command
        return unless cmd

        # POSIX character class rather than `\s`, which macOS git's regex
        # library does not support
        amend_pattern = 'commit([[:space:]].*)?[[:space:]]--amend([[:space:]]|$)'

        # Since the ps command can return invalid byte sequences for commands
        # containing unicode characters, we replace the offending characters,
        # since the pattern we're looking for will consist of ASCII characters
        unless cmd.valid_encoding?
          cmd = Overcommit::Utils.
            parent_command.
            encode('UTF-16be', invalid: :replace, replace: '?').
            encode('UTF-8')
        end

        return @amendment if
          # True if the command is a commit with the --amend flag
          @amendment = !(/\s#{amend_pattern}/ =~ cmd).nil?

        # Check for git aliases that call `commit --amend`
        `git config --get-regexp "^alias\\." "#{amend_pattern}"`.
          scan(/alias\.([-\w]+)/). # Extract the alias
          each do |match|
            return @amendment if
              # True if the command uses a git alias for `commit --amend`
              @amendment = !(/git(\.exe)?\s+#{match[0]}/ =~ cmd).nil?
          end

        @amendment
      end

      # Get a list of added, copied, or modified files that have been staged.
      # Renames and deletions are ignored, since there should be nothing to check.
      def modified_files
        unless @modified_files
          currently_staged = Overcommit::GitRepo.modified_files(staged: true)
          @modified_files = currently_staged

          # Include files modified in last commit if amending
          if amendment?
            subcmd = 'show --format=%n'
            previously_modified = Overcommit::GitRepo.modified_files(subcmd: subcmd)
            @modified_files |= filter_modified_files(previously_modified)
          end
        end
        @modified_files
      end

      # Returns the set of line numbers corresponding to the lines that were
      # changed in a specified file.
      def modified_lines_in_file(file)
        @modified_lines ||= {}
        unless @modified_lines[file]
          @modified_lines[file] =
            Overcommit::GitRepo.extract_modified_lines(file, staged: true)

          # Include lines modified in last commit if amending
          if amendment?
            subcmd = 'show --format=%n'
            @modified_lines[file] +=
              Overcommit::GitRepo.extract_modified_lines(file, subcmd: subcmd)
          end

          # Exclude lines whose content matches the diff base, e.g. lines this
          # commit restores to the content of the branch it will merge into
          if diff_base_commit
            @modified_lines[file] &=
              Overcommit::GitRepo.extract_modified_lines(file, staged: true,
                                                               refs: diff_base_commit)
          end
        end
        @modified_lines[file]
      end

      # Returns the merge base of HEAD and the configured `diff_base` ref, or
      # nil if no ref is configured or it has no merge base with HEAD.
      def diff_base_commit
        DIFF_BASE_MUTEX.synchronize do
          return @diff_base_commit if defined?(@diff_base_commit)

          @diff_base_commit = resolve_diff_base_commit
        end
      end

      private

      def resolve_diff_base_commit
        ref = @config.diff_base
        return unless ref

        result = Overcommit::Utils.execute(%W[git merge-base HEAD #{ref}])
        return result.stdout.strip if result.success?

        Overcommit::Utils.log.warning(
          "Unable to find a merge base between HEAD and diff_base `#{ref}`; " \
          'treating every line that differs from HEAD as modified'
        )
        nil
      end
    end
  end
end
