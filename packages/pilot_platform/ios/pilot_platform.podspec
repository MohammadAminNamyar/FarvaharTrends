# Local Flutter path dependency; this podspec is not configured for public publication.
Pod::Spec.new do |s|
  s.name             = 'pilot_platform'
  s.version          = '0.1.0'
  s.summary          = 'Device observations and deliberate JSON export for the FarvaharTrends pilot.'
  s.description      = 'Foreground iOS device observations and a user-controlled report share sheet.'
  s.homepage         = 'https://example.invalid/farvahartrends'
  s.license          = { :type => 'Unspecified', :text => 'Internal prototype. No public distribution license has been declared.' }
  s.author           = 'FarvaharTrends contributors'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.frameworks = 'UIKit', 'Foundation'
  s.resource_bundles = { 'pilot_platform_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
