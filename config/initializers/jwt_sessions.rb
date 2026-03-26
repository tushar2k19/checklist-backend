# Use JWT_ENCRYPTION_KEY in production; never commit real secrets
JWTSessions.encryption_key = ENV.fetch("JWT_ENCRYPTION_KEY", "tushar")
JWTSessions.access_exp_time = 36000 # 1 hour
JWTSessions.refresh_exp_time = 604800 # 1 week
