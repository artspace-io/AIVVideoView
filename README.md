# AIVVideoView

[![CI Status](https://img.shields.io/travis/Robin/AIVVideoView.svg?style=flat)](https://travis-ci.org/Robin/AIVVideoView)
[![Version](https://img.shields.io/cocoapods/v/AIVVideoView.svg?style=flat)](https://cocoapods.org/pods/AIVVideoView)
[![License](https://img.shields.io/cocoapods/l/AIVVideoView.svg?style=flat)](https://cocoapods.org/pods/AIVVideoView)
[![Platform](https://img.shields.io/cocoapods/p/AIVVideoView.svg?style=flat)](https://cocoapods.org/pods/AIVVideoView)

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Requirements

## Installation

AIVVideoView is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'AIVVideoView'
```

AIVVideoView also supports the [Swift Package Manager](https://swift.org/package-manager). In Xcode, go to
File > Add Package Dependencies... and enter:

```
https://github.com/artspace-io/AIVVideoView.git
```

or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/artspace-io/AIVVideoView.git", from: "1.1.0")
```

## Usage

```swift
import AIVVideoView

let player = AIVVideoPlayer()
let playerView = AIVVideoPlayerView()
playerView.player = player          // 绑定画面

player.playMode = .circle
player.preparePlaylist(urls)
player.play()
```

播放器所有状态都是 `@Published` 的，直接订阅即可：`$status`、`$currentTime`、`$duration`、
`$cacheProgress` 等。`.list` 模式下整个列表播完会回调 `onPlaylistCompleted`。

纯音频同样适用：不绑定 `AIVVideoPlayerView` 就行。只想复用边下边播的缓存、自己管 `AVPlayer` 的话，
可以单独用 `AIVVideoResourceLoader(url:).makePlayerItem()`。

### 可配项

```swift
// 进度回调的采样间隔，默认 1/10 秒。进度条要跟上 60fps 动画就调小，
// 只做粗粒度展示可以调大以减少主线程唤醒。
player.timeObserverInterval = CMTimeMake(value: 1, timescale: 60)

// 同时进行的下载任务上限，默认 3，全局生效。
// 多路并发播放（比如混音时同时播 4 路音频）要调到路数以上，
// 否则多出来的那几路会排队等名额，表现为迟迟不出声。
AIVVideoPlayer.setMaxConcurrentDownloads(6)

// 磁盘缓存上限，默认 500MB，视频和音频共用这一份配额。
AIVVideoCache.shared.maxCacheSize = 1024 * 1024 * 1024
```

列表里把同一个 url 重复 N 次来表达"循环播 N 遍"是支持的，切换到相邻的同一个 url 时
播放器会直接 seek 回 0 重播，不会重建播放项，衔接处不会有黑帧。

## License

AIVVideoView is available under the MIT license. See the LICENSE file for more info.
