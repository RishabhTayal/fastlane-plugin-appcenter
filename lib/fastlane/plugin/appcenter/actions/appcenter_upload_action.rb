module Fastlane
  module Actions
    module Constants
      MAX_RELEASE_NOTES_LENGTH = 5000
    end

    module SharedValues
      APPCENTER_DOWNLOAD_LINK = :APPCENTER_DOWNLOAD_LINK
      APPCENTER_BUILD_INFORMATION = :APPCENTER_BUILD_INFORMATION
    end

    class AppcenterUploadAction < Action
      # run whole upload process for dSYM files
      def self.run_dsym_upload(params)
        values = params.values
        api_token = params[:api_token]
        owner_name = params[:owner_name]
        app_name = params[:app_name]
        file = params[:ipa]
        dsym = params[:dsym]
        build_number = params[:build_number]
        version = params[:version]

        dsym_path = nil
        if dsym
          # we can use dsym parameter only if build file is ipa
          dsym_path = dsym if !file || File.extname(file) == '.ipa'
        else
          # if dsym is note set, but build is ipa - check default path
          if file && File.exist?(file) && File.extname(file) == '.ipa'
            dsym_path = file.to_s.gsub('.ipa', '.dSYM.zip')
            UI.message("dSYM is found")
          end
        end

        # if we provided valid dsym path, or <ipa_path>.dSYM.zip was found, start dSYM upload
        if dsym_path && File.exist?(dsym_path)
          if File.directory?(dsym_path)
            UI.message("dSYM path is folder, zipping...")
            dsym_path = Actions::ZipAction.run(path: dsym, output_path: dsym + ".zip")
            UI.message("dSYM files zipped")
          end

          UI.message("Starting dSYM upload...")
          
          # TODO: this should eventually be removed once we have warned of deprecation for long enough
          if File.extname(dsym_path) == ".txt"
            file_name = File.basename(dsym_path)
            dsym_upload_details = Helper::AppcenterHelper.create_mapping_upload(api_token, owner_name, app_name, file_name ,build_number, version)
          else
            dsym_upload_details = Helper::AppcenterHelper.create_dsym_upload(api_token, owner_name, app_name)
          end

          if dsym_upload_details
            symbol_upload_id = dsym_upload_details['symbol_upload_id']
            upload_url = dsym_upload_details['upload_url']

            UI.message("Uploading dSYM...")
            Helper::AppcenterHelper.upload_symbol(api_token, owner_name, app_name, dsym_path, "Apple", symbol_upload_id, upload_url)
          end
        else
          UI.user_error!("dSYM file not found")
        end
      end

      def self.run_mapping_upload(params)
        values = params.values
        api_token = params[:api_token]
        owner_name = params[:owner_name]
        app_name = params[:app_name]
        mapping = params[:mapping]
        build_number = params[:build_number]
        version = params[:version]

        if mapping == nil
          return
        end

        UI.message("Starting mapping upload...")
        mapping_name = File.basename(mapping)
        symbol_upload_details = Helper::AppcenterHelper.create_mapping_upload(api_token, owner_name, app_name, mapping_name, build_number, version)

        if symbol_upload_details
          symbol_upload_id = symbol_upload_details['symbol_upload_id']
          upload_url = symbol_upload_details['upload_url']

          UI.message("Uploading mapping...")
          Helper::AppcenterHelper.upload_symbol(api_token, owner_name, app_name, mapping, "Android", symbol_upload_id, upload_url)
        end
      end

      # run whole upload process for release
      def self.run_release_upload(params)
        values = params.values
        api_token = params[:api_token]
        owner_name = params[:owner_name]
        app_name = params[:app_name]
        destinations = params[:destinations]
        destination_type = params[:destination_type]
        mandatory_update = params[:mandatory_update]
        notify_testers = params[:notify_testers]
        release_notes = params[:release_notes]
        should_clip = params[:should_clip]
        release_notes_link = params[:release_notes_link]
        timeout = params[:timeout]

        if release_notes.length >= Constants::MAX_RELEASE_NOTES_LENGTH
          unless should_clip
            clip = UI.confirm("The release notes are limited to #{Constants::MAX_RELEASE_NOTES_LENGTH} characters, proceeding will clip them. Proceed anyway?")
            UI.abort_with_message!("Upload aborted, please edit your release notes") unless clip
            release_notes_link ||= UI.input("Provide a link for additional release notes, leave blank to skip")
          end
          read_more = "..." + (release_notes_link.to_s.empty? ? "" : "\n\n[read more](#{release_notes_link})")
          release_notes = release_notes[0, Constants::MAX_RELEASE_NOTES_LENGTH - read_more.length] + read_more
          values[:release_notes] = release_notes
          UI.message("Release notes clipped")
        end

        file = [
          params[:ipa],
          params[:apk],
          params[:aab]
        ].detect { |e| !e.to_s.empty? }

        UI.user_error!("Couldn't find build file at path '#{file}'") unless file && File.exist?(file)

        UI.message("Starting release upload...")
        upload_details = Helper::AppcenterHelper.create_release_upload(api_token, owner_name, app_name)
        if upload_details
          upload_id = upload_details['upload_id']
          upload_url = upload_details['upload_url']

          UI.message("Uploading release binary...")
          uploaded = Helper::AppcenterHelper.upload_build(api_token, owner_name, app_name, file, upload_id, upload_url, timeout)

          if uploaded
            release_id = uploaded['release_id']
            UI.message("Release '#{release_id}' committed")

            Helper::AppcenterHelper.update_release(api_token, owner_name, app_name, release_id, release_notes)

            destinations_array = destinations.split(',')
            destinations_array.each do |destination_name|
              destination = Helper::AppcenterHelper.get_destination(api_token, owner_name, app_name, destination_type, destination_name)
              if destination
                destination_id = destination['id']
                distributed_release = Helper::AppcenterHelper.add_to_destination(api_token, owner_name, app_name, release_id, destination_type, destination_id, mandatory_update, notify_testers)
                if distributed_release
                  UI.success("Release #{distributed_release['short_version']} was successfully distributed to #{destination_type} \"#{destination_name}\"")
                else
                  UI.error("Release '#{release_id}' was not found")
                end
              else
                UI.error("#{destination_type} '#{destination_name}' was not found")
              end
            end
          else 
            UI.user_error!("Failed to upload release")
          end
        end
      end

      # checks app existance, if ther is no such - creates it
      def self.get_or_create_app(params)
        api_token = params[:api_token]
        owner_name = params[:owner_name]
        app_name = params[:app_name]
        app_display_name = params[:app_display_name]
        app_os = params[:app_os]
        app_platform = params[:app_platform]

        platforms = {
          "Android" => ['Java', 'React-Native', 'Xamarin'],
          "iOS" => ['Objective-C-Swift', 'React-Native', 'Xamarin']
        }

        if Helper::AppcenterHelper.get_app(api_token, owner_name, app_name)
          return true
        end

        should_create_app = !app_display_name.to_s.empty? || !app_os.to_s.empty? || !app_platform.to_s.empty?
        
        if Helper.test? || should_create_app || UI.confirm("App with name #{app_name} not found, create one?")
          app_display_name = app_name if app_display_name.to_s.empty?
          os = app_os.to_s.empty? ?
            (Helper.test? ? "Android" : UI.select("Select OS", ["Android", "iOS"])) :
            app_os
          platform = app_platform.to_s.empty? ?
            (Helper.test? ? "Java" : UI.select("Select Platform", platforms[os])) :
            app_platform

          Helper::AppcenterHelper.create_app(api_token, owner_name, app_name, app_display_name, os, platform)
        else
          UI.error("Lane aborted")
          false
        end
      end

      def self.run(params)
        values = params.values
        upload_dsym_only = params[:upload_dsym_only]
        upload_mapping_only = params[:upload_mapping_only]

        # if app found or successfully created
        if self.get_or_create_app(params)
          self.run_release_upload(params) unless upload_dsym_only || upload_mapping_only
          self.run_dsym_upload(params) unless upload_mapping_only
          self.run_mapping_upload(params) unless upload_dsym_only
        end

        return values if Helper.test?
      end

      def self.description
        "Distribute new release to App Center"
      end

      def self.authors
        ["Microsoft"]
      end

      def self.details
        "Symbols will also be uploaded automatically if a `app.dSYM.zip` file is found next to `app.ipa`. In case it is located in a different place you can specify the path explicitly in `:dsym` parameter."
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :api_token,
                                  env_name: "APPCENTER_API_TOKEN",
                               description: "API Token for App Center",
                                  optional: false,
                                      type: String,
                              verify_block: proc do |value|
                                UI.user_error!("No API token for App Center given, pass using `api_token: 'token'`") unless value && !value.empty?
                              end),

          FastlaneCore::ConfigItem.new(key: :owner_name,
                                  env_name: "APPCENTER_OWNER_NAME",
                               description: "Owner name",
                                  optional: false,
                                      type: String,
                              verify_block: proc do |value|
                                UI.user_error!("No Owner name for App Center given, pass using `owner_name: 'name'`") unless value && !value.empty?
                              end),

          FastlaneCore::ConfigItem.new(key: :app_name,
                                  env_name: "APPCENTER_APP_NAME",
                               description: "App name. If there is no app with such name, you will be prompted to create one",
                                  optional: false,
                                      type: String,
                              verify_block: proc do |value|
                                UI.user_error!("No App name given, pass using `app_name: 'app name'`") unless value && !value.empty?
                              end),

          FastlaneCore::ConfigItem.new(key: :app_display_name,
                                  env_name: "APPCENTER_APP_DISPLAY_NAME",
                               description: "App display name to use when creating a new app",
                                  optional: true,
                                      type: String),

          FastlaneCore::ConfigItem.new(key: :app_os,
                                  env_name: "APPCENTER_APP_OS",
                               description: "App OS. Used for new app creation, if app with 'app_name' name was not found",
                                  optional: true,
                                      type: String),

          FastlaneCore::ConfigItem.new(key: :app_platform,
                                  env_name: "APPCENTER_APP_PLATFORM",
                               description: "App Platform. Used for new app creation, if app with 'app_name' name was not found",
                                  optional: true,
                                      type: String),

          FastlaneCore::ConfigItem.new(key: :apk,
                                  env_name: "APPCENTER_DISTRIBUTE_APK",
                               description: "Build release path for android build",
                             default_value: Actions.lane_context[SharedValues::GRADLE_APK_OUTPUT_PATH],
                                  optional: true,
                                      type: String,
                       conflicting_options: [:ipa, :aab],
                            conflict_block: proc do |value|
                              UI.user_error!("You can't use 'apk' and '#{value.key}' options in one run")
                            end,
                              verify_block: proc do |value|
                                accepted_formats = [".apk"]
                                UI.user_error!("Only \".apk\" formats are allowed, you provided \"#{File.extname(value)}\"") unless accepted_formats.include? File.extname(value)
                              end),

          FastlaneCore::ConfigItem.new(key: :aab,
                                  env_name: "APPCENTER_DISTRIBUTE_AAB",
                               description: "Build release path for android app bundle build (preview)",
                             default_value: Actions.lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH],
                                  optional: true,
                                      type: String,
                       conflicting_options: [:ipa, :apk],
                            conflict_block: proc do |value|
                              UI.user_error!("You can't use 'aab' and '#{value.key}' options in one run")
                            end,
                              verify_block: proc do |value|
                                accepted_formats = [".aab"]
                                UI.user_error!("Only \".aab\" formats are allowed, you provided \"#{File.extname(value)}\"") unless accepted_formats.include? File.extname(value)
                              end),

          FastlaneCore::ConfigItem.new(key: :ipa,
                                  env_name: "APPCENTER_DISTRIBUTE_IPA",
                               description: "Build release path for ios build",
                             default_value: Actions.lane_context[SharedValues::IPA_OUTPUT_PATH],
                                  optional: true,
                                      type: String,
                       conflicting_options: [:apk, :aab],
                            conflict_block: proc do |value|
                              UI.user_error!("You can't use 'ipa' and '#{value.key}' options in one run")
                            end,
                              verify_block: proc do |value|
                                accepted_formats = [".ipa"]
                                UI.user_error!("Only \".ipa\" formats are allowed, you provided \"#{File.extname(value)}\"") unless accepted_formats.include? File.extname(value)
                              end),

          FastlaneCore::ConfigItem.new(key: :dsym,
                                  env_name: "APPCENTER_DISTRIBUTE_DSYM",
                               description: "Path to your symbols file. For iOS provide path to app.dSYM.zip",
                             default_value: Actions.lane_context[SharedValues::DSYM_OUTPUT_PATH],
                                  optional: true,
                                      type: String,
                              verify_block: proc do |value|
                                deprecated_files = [".txt"]
                                if value
                                  UI.user_error!("Couldn't find dSYM file at path '#{value}'") unless File.exist?(value)
                                  UI.message("Support for *.txt has been deprecated. Please use --mapping parameter or APPCENTER_DISTRIBUTE_ANDROID_MAPPING environment variable instead.") if deprecated_files.include? File.extname(value)
                                end
                              end),

          FastlaneCore::ConfigItem.new(key: :upload_dsym_only,
                                  env_name: "APPCENTER_DISTRIBUTE_UPLOAD_DSYM_ONLY",
                               description: "Flag to upload only the dSYM file to App Center",
                                  optional: true,
                                 is_string: false,
                             default_value: false),

          FastlaneCore::ConfigItem.new(key: :mapping,
                                  env_name: "APPCENTER_DISTRIBUTE_ANDROID_MAPPING",
                               description: "Path to your Android mapping.txt",
                                  optional: true,
                                      type: String,
                              verify_block: proc do |value|
                                accepted_formats = [".txt"]
                                if value
                                  UI.user_error!("Couldn't find mapping file at path '#{value}'") unless File.exist?(value)
                                  UI.user_error!("Only \"*.txt\" formats are allowed, you provided \"#{File.name(value)}\"") unless accepted_formats.include? File.extname(value)
                                end
                              end),

          FastlaneCore::ConfigItem.new(key: :upload_mapping_only,
                                  env_name: "APPCENTER_DISTRIBUTE_UPLOAD_ANDROID_MAPPING_ONLY",
                               description: "Flag to upload only the mapping.txt file to App Center",
                                  optional: true,
                                 is_string: false,
                             default_value: false),

          FastlaneCore::ConfigItem.new(key: :group,
                                  env_name: "APPCENTER_DISTRIBUTE_GROUP",
                               description: "Comma separated list of Distribution Group names",
                                  optional: true,
                                      type: String,
                                deprecated: true,
                              verify_block: proc do |value|
                                UI.user_error!("Option `group` is deprecated. Use `destinations` and `destination_type`")
                              end),

          FastlaneCore::ConfigItem.new(key: :destinations,
                                  env_name: "APPCENTER_DISTRIBUTE_DESTINATIONS",
                               description: "Comma separated list of destination names. Both distribution groups and stores are supported. All names are required to be of the same destination type",
                             default_value: "Collaborators",
                                  optional: true,
                                      type: String),


          FastlaneCore::ConfigItem.new(key: :destination_type,
                                  env_name: "APPCENTER_DISTRIBUTE_DESTINATION_TYPE",
                               description: "Destination type of distribution destination. 'group' and 'store' are supported",
                             default_value: "group",
                                  optional: true,
                                      type: String,
                              verify_block: proc do |value|
                                UI.user_error!("No or incorrect destination type given. Use 'group' or 'store'") unless value && !value.empty? && ["group", "store"].include?(value)
                              end),

          FastlaneCore::ConfigItem.new(key: :mandatory_update,
                                  env_name: "APPCENTER_DISTRIBUTE_MANDATORY_UPDATE",
                               description: "Require users to update to this release. Ignored if destination type is 'store'",
                                  optional: true,
                                 is_string: false,
                             default_value: false),

          FastlaneCore::ConfigItem.new(key: :notify_testers,
                                  env_name: "APPCENTER_DISTRIBUTE_NOTIFY_TESTERS",
                               description: "Send email notification about release. Ignored if destination type is 'store'",
                                  optional: true,
                                 is_string: false,
                             default_value: false),

          FastlaneCore::ConfigItem.new(key: :release_notes,
                                  env_name: "APPCENTER_DISTRIBUTE_RELEASE_NOTES",
                               description: "Release notes",
                             default_value: Actions.lane_context[SharedValues::FL_CHANGELOG] || "No changelog given",
                                  optional: true,
                                      type: String),

          FastlaneCore::ConfigItem.new(key: :should_clip,
                                  env_name: "APPCENTER_DISTRIBUTE_RELEASE_NOTES_CLIPPING",
                               description: "Clip release notes if its length is more then #{Constants::MAX_RELEASE_NOTES_LENGTH}, true by default",
                                  optional: true,
                                 is_string: false,
                             default_value: true),

          FastlaneCore::ConfigItem.new(key: :release_notes_link,
                                  env_name: "APPCENTER_DISTRIBUTE_RELEASE_NOTES_LINK",
                               description: "Additional release notes link",
                                  optional: true,
                                      type: String),

          FastlaneCore::ConfigItem.new(key: :build_number,
                                       env_name: "APPCENTER_DISTRIBUTE_BUILD_NUMBER",
                                       description: "The build number. Used (and required) for uploading Android ProGuard mapping file",
                                       optional: true,
                                       type: String),

          FastlaneCore::ConfigItem.new(key: :version,
                                       env_name: "APPCENTER_DISTRIBUTE_VERSION",
                                       description: "The version number. Used (and required) for uploading Android ProGuard mapping file",
                                       optional: true,
                                       type: String),

          FastlaneCore::ConfigItem.new(key: :timeout,
                                       env_name: "APPCENTER_DISTRIBUTE_TIMEOUT",
                                       description: "Request timeout in seconds",
                                       optional: true,
                                       type: Integer),
        ]
      end

      def self.output
        [
          ['APPCENTER_DOWNLOAD_LINK', 'The newly generated download link for this build'],
          ['APPCENTER_BUILD_INFORMATION', 'contains all keys/values from the App Center API']
        ]
      end

      def self.is_supported?(platform)
        true
      end

      def self.example_code
        [
          'appcenter_upload(
            api_token: "...",
            owner_name: "appcenter_owner",
            app_name: "testing_app",
            apk: "./app-release.apk",
            destinations: "Testers",
            destination_type: "group",
            build_number: "3",
            version: "1.0.0",
            mapping: "./mapping.txt",
            release_notes: "release notes",
            notify_testers: false
          )',
          'appcenter_upload(
            api_token: "...",
            owner_name: "appcenter_owner",
            app_name: "testing_app",
            apk: "./app-release.ipa",
            destinations: "Testers,Alpha",
            destination_type: "group",
            dsym: "./app.dSYM.zip",
            release_notes: "release notes",
            notify_testers: false
          )',
          'appcenter_upload(
            api_token: "...",
            owner_name: "appcenter_owner",
            app_name: "testing_app",
            aab: "./app.aab",
            destinations: "Alpha",
            destination_type: "store",
            build_number: "3",
            version: "1.0.0",
            mapping: "./mapping.txt",
            release_notes: "release notes",
            notify_testers: false
          )'
        ]
      end
    end
  end
end