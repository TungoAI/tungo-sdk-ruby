# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'tungo-sdk'
  spec.version       = '0.1.0'
  spec.authors       = ['Tungo AI']
  spec.email         = ['noreply@tungo.kz']
  spec.summary       = 'Официальный Ruby SDK для платформы ИИ-бухгалтерии Tungo AI'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'
  spec.files         = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']
end
