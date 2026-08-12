#!/usr/bin/env ruby
# frozen_string_literal: true

# Updates only the build configurations belonging to the macOS Textream target.
# Keeping this scoped prevents a macOS release tag from changing the independent
# marketing version of the TextreamiOS app and its test bundle.

version = ARGV.fetch(0) do
  abort "Usage: #{$PROGRAM_NAME} <version> [project.pbxproj]"
end

unless version.match?(/\A\d+(?:\.\d+){0,2}\z/)
  abort "Invalid Apple marketing version: #{version.inspect}"
end

project_path = ARGV[1] || File.expand_path(
  "../Textream/Textream.xcodeproj/project.pbxproj",
  __dir__
)
source = File.binread(project_path)

native_targets = source[/\/\* Begin PBXNativeTarget section \*\/.*?\/\* End PBXNativeTarget section \*\//m]
abort "PBXNativeTarget section not found" unless native_targets

target = native_targets.match(
  /^\s*[0-9A-F]+ \/\* Textream \*\/ = \{(?<body>.*?)^\s*\};/m
)
abort 'macOS target "Textream" not found' unless target

configuration_list_id = target[:body][
  /buildConfigurationList = ([0-9A-F]+) \/\* Build configuration list for PBXNativeTarget "Textream" \*\//,
  1
]
abort "macOS target configuration list not found" unless configuration_list_id

configuration_lists = source[/\/\* Begin XCConfigurationList section \*\/.*?\/\* End XCConfigurationList section \*\//m]
abort "XCConfigurationList section not found" unless configuration_lists

configuration_list = configuration_lists.match(
  /^\s*#{Regexp.escape(configuration_list_id)} \/\*.*?\*\/ = \{(?<body>.*?)^\s*\};/m
)
abort "macOS target configuration list block not found" unless configuration_list

configuration_ids_match = configuration_list[:body].match(
  /buildConfigurations = \((?<ids>.*?)\);/m
)
configuration_ids = configuration_ids_match&.[](:ids)
  &.scan(/^\s*([0-9A-F]+) \/\*/)&.flatten

unless configuration_ids&.length == 3
  abort "Expected 3 macOS target configurations, found #{configuration_ids&.length || 0}"
end

updated = source.dup
configuration_ids.each do |configuration_id|
  block_pattern = /^\s*#{Regexp.escape(configuration_id)} \/\*.*?\*\/ = \{.*?^\s*\};/m
  block = updated[block_pattern]
  abort "Configuration #{configuration_id} not found" unless block

  settings = block.scan(/^\s*MARKETING_VERSION = [^;]+;/)
  unless settings.length == 1
    abort "Expected one MARKETING_VERSION in #{configuration_id}, found #{settings.length}"
  end

  replacement = block.sub(
    /^(\s*MARKETING_VERSION = )[^;]+;/,
    "\\1#{version};"
  )
  updated.sub!(block, replacement)
end

File.binwrite(project_path, updated)
puts "Set macOS Textream marketing version to #{version} in #{configuration_ids.length} configurations."
