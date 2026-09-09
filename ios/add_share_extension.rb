# CI 上把 ShareExtension target 注入 Runner.xcodeproj（本地没有 Mac/Xcode，
# 不在仓库里长期维护 pbxproj 的 extension 配置，构建前动态生成，幂等）。
# 用法：cd ios && ruby add_share_extension.rb
require 'xcodeproj'

proj_path = File.expand_path('Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(proj_path)

if project.targets.any? { |t| t.name == 'ShareExtension' }
  puts 'ShareExtension target already present, skipping'
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' }
abort 'Runner target not found' unless runner

# 版本号与主 App 保持一致（否则上传 ASC 报版本不匹配 warning/error）
gen = File.read(File.expand_path('Flutter/Generated.xcconfig', __dir__))
build_name = gen[/^FLUTTER_BUILD_NAME=(.*)$/, 1]&.strip || '1.0.0'
build_number = gen[/^FLUTTER_BUILD_NUMBER=(.*)$/, 1]&.strip || '1'
deploy = runner.build_configurations.first
           .resolve_build_setting('IPHONEOS_DEPLOYMENT_TARGET') || '13.0'

target = project.new_target(:app_extension, 'ShareExtension', :ios, deploy)
group = project.new_group('ShareExtension', 'ShareExtension')
target.add_file_references([group.new_reference('ShareViewController.swift')])

target.build_configurations.each do |c|
  bs = c.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.weavejam.pdfcast.share'
  bs['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['CODE_SIGN_ENTITLEMENTS'] = 'ShareExtension/ShareExtension.entitlements'
  bs['CODE_SIGN_STYLE'] = 'Automatic'
  bs['SWIFT_VERSION'] = '5.0'
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = deploy
  bs['MARKETING_VERSION'] = build_name
  bs['CURRENT_PROJECT_VERSION'] = build_number
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['SKIP_INSTALL'] = 'YES'
  bs['LD_RUNPATH_SEARCH_PATHS'] =
    ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

runner.add_dependency(target)
embed = runner.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(target.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "ShareExtension target injected (version #{build_name}+#{build_number}, iOS #{deploy})"
