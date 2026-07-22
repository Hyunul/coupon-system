-- KEYS[1]=stock:{eventId}, KEYS[2]=issued:{eventId}, KEYS[3]=stream:issue
-- ARGV[1]=userId, ARGV[2]=eventId, ARGV[3]=issuedAt(ISO)
-- 검사+차감+등록+이벤트 발행까지 원자 실행 (roadmap 4.4 채택안 + Phase 3 Stream)
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
    return 'DUPLICATE'
end
local stock = tonumber(redis.call('GET', KEYS[1]))
if stock == nil or stock <= 0 then
    return 'SOLD_OUT'
end
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
redis.call('XADD', KEYS[3], '*', 'eventId', ARGV[2], 'userId', ARGV[1], 'issuedAt', ARGV[3])
return 'OK'
