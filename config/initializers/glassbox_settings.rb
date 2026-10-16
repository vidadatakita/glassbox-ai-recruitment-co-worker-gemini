# Boot check for the settings registry (ONP-2, D34): refuse to start with a missing or invalid
# required setting, naming the key. See lib/glassbox/settings.rb.
Glassbox::Settings.validate!(ENV)
