return {
    BASE_URL        = "https://www.royalroad.com",
    USER_AGENT      = "Mozilla/5.0 (compatible; KOReader/1.0)",

    HTTP = {
        CONNECT_TIMEOUT = 10,
        TOTAL_TIMEOUT   = 60,
    },

    NETWORK = {
        SCHEDULE_DELAY      = 0.1,
        YIELD_DELAY         = 0.01,
        -- Page cache is per-URL and shared across all callers within a session.
        -- A story page fetched for update-checking will satisfy a subsequent
        -- fetchPageCached call for the same URL within this window.
        PAGE_CACHE_TTL      = 300,
        DEFAULT_RATE_LIMIT  = 1.5,
        RATE_LIMIT_BACKOFF  = 30,
    },

    CACHE = {
        MAX_COVERS = 50,
    },

    SEARCH = {
        MAX_RESULTS   = 20,
        URL_PATH      = "/fictions/search?title=",
        PAGE_PARAM    = "&page=",
    },

    DEFAULTS = {
        MOSAIC_COLS     = 3,
        MOSAIC_ROWS     = 2,
        VIEW_MODE       = "list",
        SORT_MODE       = "title",
        COLLECTION_NAME = "Royal Road",
    },
}
