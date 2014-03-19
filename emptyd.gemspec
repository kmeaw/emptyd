# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'emptyd/version'

Gem::Specification.new do |spec|
  spec.name          = "emptyd"
  spec.version       = Emptyd::VERSION
  spec.authors       = ["kmeaw"]
  spec.email         = ["kmeaw@larkit.ru"]
  spec.description   = %q{An HTTP interface to run a single command on a cluster.}
  spec.summary       = %q{Run commands on multiple hosts over SSH}
  spec.homepage      = "https://github.com/kmeaw/emptyd"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"

  spec.add_dependency "eventmachine-le"
  spec.add_dependency "em-udns"
  spec.add_dependency "em-ssh"
  spec.add_dependency "eventmachine_httpserver"
end
