Pod::Spec.new do |s|
  s.name             = 'AIVVideoView'
  s.version          = '1.0.1'
  s.summary          = 'A video player with edge-to-edge caching support.'
  s.description      = '基于 AVAssetResourceLoader 的支持边播边缓存的视频播放器，所有状态可通过 Combine 观察。'
  s.homepage         = 'https://github.com/artspace-io/AIVVideoView'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Robin' => 'enamourchen@outlook.com' }

  s.source           = { :git => 'https://github.com/artspace-io/AIVVideoView.git', :tag => s.version.to_s }

  s.ios.deployment_target = '16.0'
  s.swift_version = '5.7'

  s.source_files = 'AIVVideoView/Classes/**/*'
end
