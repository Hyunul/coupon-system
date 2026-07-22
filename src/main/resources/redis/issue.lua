-- KEYS[1]=stock:{eventId}, KEYS[2]=issued:{eventId}, ARGV[1]=userId
-- 검사+차감+등록을 단일 스크립트로 원자 실행 (roadmap 4.4 전략 ③)
-- 발급 이벤트 Stream 발행(XADD)은 Phase 3 비동기 전환에서 추가한다
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
    return 'DUPLICATE'
end
local stock = tonumber(redis.call('GET', KEYS[1]))
if stock == nil or stock <= 0 then
    return 'SOLD_OUT'
end
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
return 'OK'
