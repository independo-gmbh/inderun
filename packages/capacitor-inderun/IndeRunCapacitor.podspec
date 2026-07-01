Pod::Spec.new do |s|
  s.name = 'IndeRunCapacitor'
  s.version = '0.1.0'
  s.summary = 'Thin Capacitor bridge for IndeRun.'
  s.license = 'MIT'
  s.homepage = 'https://github.com/independo-gmbh/inderun'
  s.author = 'Independo'
  s.source = { :git => 'https://github.com/independo-gmbh/inderun.git', :tag => s.version.to_s }
  s.source_files = 'ios/Sources/IndeRunCapacitorPlugin/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'

  s.dependency 'Capacitor'

  # TODO(#23): These pods must be published before this podspec is usable outside the monorepo.
  # Pod names mirror the SPM library product names from ios/IndeRun/Package.swift.
  s.dependency 'IndeRun'                # SPM product: IndeRun (IndeRunSwift target)
  s.dependency 'IndeRunCore'            # SPM product: IndeRunCore
  s.dependency 'IndeRunAppleProviders'  # SPM product: IndeRunAppleProviders
  s.dependency 'IndeRunOpenAIProviders' # SPM product: IndeRunOpenAIProviders
end
