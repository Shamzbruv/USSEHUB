// The existing analytics RPC groups events and revenue by UTC calendar day.
export function advertisingPeriod(report) {
    const days = Number(report?.days);
    const generated = new Date(report?.generated_at);
    if (!Number.isInteger(days) || days < 1 || days > 3660 || !report?.generated_at || Number.isNaN(generated.getTime())) return null;
    const end = new Date(Date.UTC(generated.getUTCFullYear(), generated.getUTCMonth(), generated.getUTCDate()));
    const start = new Date(end);
    start.setUTCDate(start.getUTCDate() - days + 1);
    const date = value => value.toLocaleDateString('en-GB', {timeZone:'UTC', day:'numeric', month:'short', year:'numeric'});
    return {
        days,
        start: start.toISOString().slice(0,10),
        end: end.toISOString().slice(0,10),
        label: `For the period: ${date(start)}${days === 1 ? '' : ' – ' + date(end)} (UTC)`,
        updated: `Updated ${generated.toLocaleString('en-GB', {timeZone:'America/Jamaica', day:'numeric', month:'short', year:'numeric', hour:'2-digit', minute:'2-digit', hour12:true})} · Jamaica time`
    };
}

// Commit matching analytics and delivery together. A failed or superseded range
// request cannot relabel the last successful report or overwrite a newer one.
export function createAdvertisingReportLoader({rpc, commit}) {
    let generation = 0;
    return async function load(days) {
        if (!Number.isInteger(days) || days < 1 || days > 3660) throw new Error('Choose a valid reporting period.');
        const current = ++generation;
        const [analytics, delivery] = await Promise.all([
            rpc('get_admin_advertising_analytics', {p_days:days}),
            rpc('get_admin_advertisement_delivery', {p_days:days})
        ]);
        if (current !== generation) return false;
        if (analytics.error || delivery.error) throw new Error(analytics.error?.message || delivery.error.message);
        const period = advertisingPeriod(analytics.data);
        if (!period || period.days !== days || !Array.isArray(delivery.data?.advertisements)) throw new Error('The reporting period could not be verified. Please refresh and try again.');
        commit({analytics:analytics.data, advertisements:delivery.data.advertisements});
        return true;
    };
}
