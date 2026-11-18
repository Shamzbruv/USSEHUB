import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.108.2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './usse-public-config.mjs';
import { escapeHtml as e } from './usse-marketplace-core.mjs?v=taxonomy2';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = id => document.getElementById(id);
const form = $('taxonomy-add-form');
let catalogue = null;
let authorized = false;
let saving = false;
let authVersion = 0;

function notice(message, error = false) {
    $('taxonomy-notice').textContent = message;
    $('taxonomy-notice').dataset.error = String(error);
}

function setOptions(select, choices, placeholder) {
    const previous = select.value;
    select.replaceChildren(new Option(placeholder, ''), ...choices.map(value => new Option(value, value)));
    select.value = choices.includes(previous) ? previous : '';
}

function parentPath() {
    return ['category', 'secondary', 'tertiary'].slice(0, Number(form.elements.level.value) - 1)
        .map(name => form.elements[name].value);
}

function updateParents() {
    if (!catalogue) return;
    const { scope, level, category, secondary, tertiary } = form.elements;
    const source = catalogue[scope.value];
    const depth = Number(level.value);
    setOptions(category, Object.keys(source), 'Choose a category');
    setOptions(secondary, scope.value === 'directory' ? Object.keys(source[category.value] || {}) : [], 'Choose a subcategory');
    setOptions(tertiary, source[category.value]?.[secondary.value]?.tertiary || [], 'Choose a specialization');
    for (const [index, name] of ['category', 'secondary', 'tertiary'].entries()) {
        const needed = index < depth - 1;
        form.elements[name].disabled = !needed;
        form.elements[name].required = needed;
        $('taxonomy-' + name + '-field').hidden = !needed;
    }
    $('taxonomy-placement').textContent = depth === 1 ? 'This choice will appear as a main category.'
        : 'Add under ' + (parentPath().filter(Boolean).join(' › ') || 'the parent you choose above') + '.';
    render();
}

function changeScope() {
    const levels = form.elements.scope.value === 'marketplace'
        ? ['Category', 'Subsegment'] : ['Category', 'Subcategory', 'Specialization', 'Specific type'];
    form.elements.level.replaceChildren(...levels.map((name, index) => new Option(name, String(index + 1))));
    form.elements.level.value = '2';
    for (const name of ['category', 'secondary', 'tertiary']) form.elements[name].value = '';
    updateParents();
}

function render() {
    if (!catalogue) return;
    const source = catalogue[form.elements.scope.value];
    const query = $('taxonomy-search').value.trim().toLocaleLowerCase();
    const rows = Object.entries(source).filter(([category, children]) =>
        JSON.stringify([category, children]).toLocaleLowerCase().includes(query));
    $('taxonomy-list').innerHTML = rows.map(([category, children]) => {
        const content = Array.isArray(children)
            ? children.map(name => `<li>${e(name)}</li>`).join('')
            : Object.entries(children).map(([name, group]) => `<li><strong>${e(name)}</strong>${group.tertiary?.length ? '<p>' + group.tertiary.map(e).join(' · ') + '</p>' : ''}${group.specific?.length ? '<p>' + group.specific.map(e).join(' · ') + '</p>' : ''}</li>`).join('');
        return `<details${query ? ' open' : ''}><summary>${e(category)}</summary>${content ? '<ul>' + content + '</ul>' : '<p>No subcategories added yet.</p>'}</details>`;
    }).join('') || '<p>No matching choices.</p>';
}

async function refresh(version = authVersion) {
    const { data, error } = await sb.rpc('business_taxonomy');
    if (version !== authVersion) return false;
    if (error) throw new Error('The category editor could not load. Please contact Shamar to check the database setup.');
    catalogue = data;
    updateParents();
    return true;
}

form.elements.scope.onchange = changeScope;
for (const name of ['level', 'category', 'secondary', 'tertiary']) form.elements[name].onchange = updateParents;
$('taxonomy-search').oninput = render;
$('taxonomy-refresh').onclick = async () => {
    try { await refresh(); notice('Choices refreshed.'); }
    catch (error) { notice(error.message, true); }
};
form.onsubmit = async event => {
    event.preventDefault();
    if (!authorized || saving) return;
    saving = true;
    const scope = form.elements.scope.value;
    const name = form.elements.name.value.trim();
    const parent = parentPath();
    form.querySelectorAll('input,select,button').forEach(control => { control.disabled = true; });
    $('taxonomy-result').textContent = 'Saving…';
    try {
        const { data, error } = await sb.rpc('add_business_taxonomy_entry', {
            p_scope: scope, p_parent: parent, p_name: name
        });
        if (error) throw error;
        if (!authorized) return;
        catalogue[scope] = data;
        form.elements.name.value = '';
        $('taxonomy-result').textContent = name + ' is available. Refresh any open posting form to use it.';
        notice('Category catalogue updated.');
    } catch (error) {
        $('taxonomy-result').textContent = error.message;
    } finally {
        saving = false;
        form.querySelectorAll('input,select,button').forEach(control => { control.disabled = false; });
        if (authorized) updateParents();
    }
};

async function init() {
    const version = ++authVersion;
    authorized = false;
    $('taxonomy-workspace').hidden = true;
    try {
        const { data: { user }, error } = await sb.auth.getUser();
        if (version !== authVersion) return;
        if (error || !user) {
            $('taxonomy-login').hidden = false;
            notice('Sign in to manage categories and subsegments.');
            return;
        }
        const { data: profile, error: profileError } = await sb.from('profiles')
            .select('role,account_status').eq('id', user.id).maybeSingle();
        if (version !== authVersion) return;
        if (profileError || profile?.role !== 'admin' || profile.account_status !== 'active' || !user.email_confirmed_at) {
            throw new Error('An active administrator account with a confirmed email is required.');
        }
        $('taxonomy-login').hidden = true;
        if (!await refresh(version)) return;
        authorized = true;
        $('taxonomy-workspace').hidden = false;
        changeScope();
        notice('Choose a catalogue to add a category or subsegment.');
    } catch (error) {
        notice(error.message, true);
    }
}
$('taxonomy-login-form').onsubmit = async event => {
    event.preventDefault();
    const target = event.currentTarget;
    const button = target.querySelector('button');
    button.disabled = true;
    try {
        const { error } = await sb.auth.signInWithPassword({ email: target.elements.email.value.trim(), password: target.elements.password.value });
        if (error) throw error;
        target.elements.password.value = '';
        await init();
    } catch (error) { notice(error.message, true); }
    finally { button.disabled = false; }
};
sb.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') {
        authVersion++;
        authorized = false;
        catalogue = null;
        $('taxonomy-workspace').hidden = true;
        $('taxonomy-login').hidden = false;
        $('taxonomy-list').replaceChildren();
        notice('Signed out.');
    }
});
await init();
