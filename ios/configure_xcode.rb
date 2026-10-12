require 'xcodeproj'

project_path = 'Runner.xcodeproj'
begin
  project = Xcodeproj::Project.open(project_path)
  target = project.targets.find { |t| t.name == 'Runner' }

  # 1. Config Builder Settings
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Runner/Runner-Bridging-Header.h'
    # Include NDI headers AND Flutter's generated headers AND OMT/libvmx headers
    config.build_settings['HEADER_SEARCH_PATHS'] = '$(inherited) $(PROJECT_DIR)/NDISDK/include $(SRCROOT)/Flutter $(SRCROOT)/Runner $(SRCROOT)/Runner/libvmx'
    config.build_settings['LIBRARY_SEARCH_PATHS'] = '$(inherited) $(PROJECT_DIR)/NDISDK/lib'
    config.build_settings['ENABLE_BITCODE'] = 'NO'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
    config.build_settings['CLANG_CXX_LIBRARY'] = 'libc++'
    config.build_settings['OTHER_CFLAGS'] = '$(inherited) -fdeclspec'
    config.build_settings['OTHER_CPLUSPLUSFLAGS'] = '$(inherited) -fdeclspec'
    # Never treat warnings as errors (fixes 3rd-party pod deprecation warnings)
    config.build_settings['SWIFT_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
    config.build_settings['GCC_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
    config.build_settings['CLANG_WARN_NULLABILITY_COMPLETENESS'] = 'NO'
    
    # 🚨 CRUCIAL : Définition statique pour que les headers NDI fonctionnent sur iOS
    defs = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] || ['$(inherited)']
    defs << 'PROCESSINGNDILIB_STATIC=1'
    config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = defs.uniq
    
    # Évite les erreurs "libarpack.a" is not an object file
    config.build_settings['OTHER_LDFLAGS'] = '$(inherited) -all_load -ObjC'
  end

  # 2. Add Swift and C++/ObjC files to the project
  group = project.main_group.find_subpath('Runner', true)
  files = [
    'NDIManager.swift', 'NDIView.swift', 'NdiCameraPreview.swift', 'CrashLogger.swift', 'Runner-Bridging-Header.h',
    'OMTProtocol.swift', 'OMTDiscovery.swift', 'OMTVideoCapture.swift', 'OMTSender.swift', 'OMTManager.swift',
    'OMTVideoEncoder.swift', 'OMTTestPattern.swift', 'OMTCameraPreview.swift',
    'OMTReceiver.swift', 'OMTReceiverView.swift', 'OMTVMXBridge.h', 'OMTVMXBridge.mm',
    'libvmx/vmxcodec.h', 'libvmx/vmxcodec.cpp', 'libvmx/vmxcodec_arm.h', 'libvmx/vmxcodec_arm.cpp',
    'libvmx/vmxcodec_common.h', 'libvmx/thread_tasks.h', 'libvmx/sse2neon.h', 'libvmx/framework.h', 'libvmx/pch.h'
  ]

  files.each do |f|
    file_ref = group.find_file_by_path(f)
    if file_ref.nil?
      file_ref = group.new_file(f)
      target.source_build_phase.add_file_reference(file_ref) unless f.end_with?('.h')
    end
  end

  # 3. Add Native iOS Frameworks (AJOUT DE ACCELERATE POUR NDI, NETWORK POUR OMT)
  ['VideoToolbox.framework', 'AudioToolbox.framework', 'CoreMedia.framework', 'CoreVideo.framework', 'Accelerate.framework', 'Network.framework'].each do |framework|
    path = "System/Library/Frameworks/#{framework}"
    file_ref = project.frameworks_group.find_file_by_path(framework) || project.frameworks_group.new_file(path, :developer_dir)
    target.frameworks_build_phase.add_file_reference(file_ref)
  end

  # 4. LINK NDI LIBRARY (.a)
  ndi_lib_name = 'libndi_ios.a' 
  ndi_lib_path = "NDISDK/lib/#{ndi_lib_name}"
  ndi_file_ref = project.frameworks_group.find_file_by_path(ndi_lib_path) || project.frameworks_group.new_file(ndi_lib_path)
  target.frameworks_build_phase.add_file_reference(ndi_file_ref)

  project.save
  puts "✅ Xcode project configured with STATIC NDI support."
rescue => e
  puts "❌ ERROR: Failed to configure Xcode project: #{e.message}"
  exit 1
end
