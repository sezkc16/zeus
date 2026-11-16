Pod::Spec.new do |s|
  s.name             = 'zorox_mpv_pip'
  s.version          = '0.0.1'
  s.summary          = 'iOS Picture-in-Picture for the mpv player (ZoroX).'
  s.description      = 'Wraps mpv software-rendered frames as CMSampleBuffers and enqueues them into an AVSampleBufferDisplayLayer for AVPictureInPictureController.'
  s.homepage         = 'https://github.com/kcsuresh18/zorox'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'ZoroX' => 'dev@zorox.app' }
  s.source           = { :git => 'https://github.com/kcsuresh18/zorox.git', :tag => s.version.to_s }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.6'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.static_framework = true
end
