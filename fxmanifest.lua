fx_version 'cerulean'

game 'common'

server_script 'Queue.lua'
server_script '@frp_lib/lib/i18n.lua'
server_script 'locale/*.lua'


client_script 'ConnectionAck.lua'

rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

lua54 'yes'