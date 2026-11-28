// Production numeric parser + bridge, injected transport/time only; no live app/player action. — GPT-6.1 Sol
import Foundation
private final class VolumeTransport: VideoBridgeTransport {
 var onReply: (@MainActor (VideoBridgeReply) -> Void)?
 var posts: [(id:String, action:String, value:Int?)] = []
 func post(requestId:String,action:String,issuedAt:Int,seconds:Int?,volumePercent:Int?) { posts.append((requestId,action,volumePercent)) }
}
@main enum YouTubeVolumeTests {
 @MainActor static func main() {
  var checks=0
  func check(_ value:Bool,_ message:String) { precondition(value,message);checks += 1 }
  let config=PhraseConfiguration(rows:[.youtubeVolumePhrase:["YouTube volume"],.spotifyVolumePhrase:["Spotify volume"],.outputVolumePhrase:["Set volume"]])
  let dictionary=PhraseDictionaries(savedByTrigger:[:],active:config)
  let pattern=PhrasePattern(slot:.youtubeVolumePhrase,text:"YouTube volume",similar:true,dictionaries:dictionary)
  func parse(_ text:String)->[Int] {
   var parser=SpotifyVolumePhrase();parser.audio(level:0.2,seconds:0.1,at:0);parser.update(text,at:1,timings:nil)
   return parser.poll(at:1,prefixes:[pattern]).map(\.volume)
  }
  for n in 0...100 { check(parse("YouTube volume \(n) percent")==[n],"Numeric default") }
  for (text,n) in [("zero",0),("thirty",30),("one hundred",100)] { check(parse("YouTube volume "+text)==[n],"Existing spoken number decoder") }
  for text in ["YouTube volume -1","YouTube volume 101","YouTube volume 2.5","YouTube volume normal","Set volume thirty","Spotify volume thirty","Don't YouTube volume thirty","I said YouTube volume thirty"] { check(parse(text).isEmpty,"No malformed, other-player or mentioned command") }
  for capability in [nil,[],["youtubeabsolutevolume"],["youtubeAbsoluteVolume"]] as [[String]?] {
   let transport=VolumeTransport();let bridge=VideoBridge(transport:transport,schedule:{_,_ in {} });var outcome:VideoCommandOutcome?
   bridge.setYouTubeVolume(30){outcome=$0};check(transport.posts.count==1 && transport.posts[0].action=="status","Fresh status only")
   bridge.receive(.init(requestId:transport.posts[0].id,action:"status",state:"available",protocolVersion:1,capabilities:capability))
   if capability != ["youtubeAbsoluteVolume"] { check(transport.posts.count==1 && outcome == .unavailable,"Old/unknown bridge never receives volume");continue }
   check(transport.posts.count==2 && transport.posts[1].action=="setVolume" && transport.posts[1].value==30,"Capability then one value send")
   let id=transport.posts[1].id
   bridge.receive(.init(requestId:id,action:"setVolume",state:"done",changed:false,protocolVersion:1,volumePercent:30,playing:false,paused:true,muted:true,confirmed:true))
   check(outcome == .volume(30),"Already-target muted paused player is confirmed")
   bridge.receive(.init(requestId:id,action:"setVolume",state:"done",changed:true,protocolVersion:1))
   check(transport.posts.count==2 && outcome == .volume(30),"Duplicate does not resend/change result")
  }
  for mutation in 0..<8 {
   let transport=VolumeTransport();let bridge=VideoBridge(transport:transport,schedule:{_,_ in {} });var result:VideoCommandOutcome?
   bridge.setYouTubeVolume(30){result=$0};bridge.receive(.init(requestId:transport.posts[0].id,action:"status",state:"available",protocolVersion:1,capabilities:["youtubeAbsoluteVolume"]))
   var reply=VideoBridgeReply(requestId:transport.posts[1].id,action:"setVolume",state:"done",changed:true,protocolVersion:1,volumePercent:30,playing:true,paused:false,muted:false,confirmed:true)
   switch mutation {case 0:reply.confirmed=nil;case 1:reply.confirmed=false;case 2:reply.volumePercent=31;case 3:reply.playing=nil;case 4:reply.paused=nil;case 5:reply.muted=nil;case 6:reply.paused=true;default:reply.protocolVersion=2}
   bridge.receive(reply);check(result != .volume(30),"Strict completed readback required");check(transport.posts.count==2,"Unknown never retried")
  }
  let transport=VolumeTransport();let bridge=VideoBridge(transport:transport,schedule:{_,_ in {} });var outcome:VideoCommandOutcome?
  bridge.setYouTubeVolume(30,shouldSend:{false}){outcome=$0};bridge.receive(.init(requestId:transport.posts[0].id,action:"status",state:"available",protocolVersion:1,capabilities:["youtubeAbsoluteVolume"]))
  check(outcome == .rejected && transport.posts.count==1,"Expired/cancelled command after async status cannot send")
  bridge.setYouTubeVolume(101){outcome=$0};check(outcome == .rejected && transport.posts.count==1,"Invalid input sends nothing")
  print("YouTube numeric/capability/strict readback: \(checks) checks passed")
 }
}
