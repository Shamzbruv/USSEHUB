        import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

        const SUPABASE_URL = 'https://zcptuqrlovflcpqszery.supabase.co';
        const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpjcHR1cXJsb3ZmbGNwcXN6ZXJ5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMDMxMzcsImV4cCI6MjA5NTU3OTEzN30.kl9BwGqwWEVWYtxYWrG7xigK_EOGZxLQBNbZZp7tfPw';
        const WHATSAPP_NUMBER = '18764271661';

        const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

        // ==========================================
        // STATE
        // ==========================================
        let currentUser = null;
        let currentProfile = null;
        let activeCategory = null;
        let listingsOffset = 0;
        const LISTINGS_PER_PAGE = 10;
        let totalListingsCount = 0;

        // ==========================================
        // EXPOSE TO GLOBAL SCOPE (for onclick attrs)
        // ==========================================
        window.performSearch = performSearch;
        window.filterByCategory = filterByCategory;
        window.clearCategoryFilter = clearCategoryFilter;
        window.handlePostListingClick = handlePostListingClick;
        window.handleLogin = handleLogin;
        window.handleRegister = handleRegister;
        window.handleForgotPassword = handleForgotPassword;
        window.handleSidebarLogin = handleSidebarLogin;
        window.handleLogout = handleLogout;
        window.handleListingSubmit = handleListingSubmit;
        window.handleWhatsAppClick = handleWhatsAppClick;
        window.loadMoreListings = loadMoreListings;
        window.openModal = openModal;
        window.closeModal = closeModal;
        window.switchAuthTab = switchAuthTab;
        
        window.openConsultationModal = function(listingId, method, contact) {
            document.getElementById('consultation-listing-id').value = listingId;
            document.getElementById('consultation-method').value = method;
            document.getElementById('consultation-contact').value = contact;
            openModal('consultation-modal');
        };
        
        window.openListingDetailsModal = function(listingJson) {
            const l = JSON.parse(decodeURIComponent(listingJson));
            const content = document.getElementById('ld-content');
            
            const isJob = l.category === 'JOBS & CAREERS';
            
            content.innerHTML = `
                <div style="display:flex; gap: 16px; margin-bottom: 20px;">
                    ${l.image_url ? `<img src="${escHtml(l.image_url)}" style="width:100px; height:100px; object-fit:cover; border-radius:12px; border:1px solid var(--glass-border); flex-shrink:0;">` : `<div style="width:100px; height:100px; background:var(--glass-bg); border-radius:12px; display:flex; align-items:center; justify-content:center; font-size:2rem; color:var(--muted); border:1px solid var(--glass-border);">🏢</div>`}
                    <div>
                        <h2 style="margin:0 0 8px 0; font-size:1.5rem;">${escHtml(l.business_name)}</h2>
                        <div style="color:var(--muted); font-size:0.9rem; margin-bottom: 4px;">
                            <strong>${isJob ? 'Industry' : 'Category'}:</strong> ${escHtml(l.category)} 
                            ${l.subcategory ? ` &bull; <strong>${isJob ? 'Job Type' : 'Subcategory'}:</strong> ${escHtml(l.subcategory)}` : ''}
                        </div>
                        <div style="color:var(--muted); font-size:0.9rem;">
                            <strong>Location:</strong> ${escHtml(formatLocation(l.location))}
                        </div>
                    </div>
                </div>
                
                <div style="background:var(--glass-bg); padding: 16px; border-radius: 12px; border: 1px solid var(--glass-border); margin-bottom: 20px;">
                    <h3 style="margin-top:0; margin-bottom:12px; font-size:1.1rem;">${isJob ? 'Job Description & Requirements' : 'Description'}</h3>
                    <p style="white-space: pre-wrap; font-size:0.95rem; line-height:1.6; color:var(--text); margin:0;">${escHtml(l.description)}</p>
                </div>
                
                <div style="display:flex; gap: 12px; flex-wrap:wrap; justify-content: flex-end; align-items:center; border-top: 1px solid var(--glass-border); padding-top:16px;">
                    <span style="color:var(--muted); font-size:0.85rem; margin-right:auto;">Posted: ${new Date(l.created_at).toLocaleDateString()}</span>
                    ${l.phone ? `<a href="tel:${escHtml(l.phone).replace(/\D/g,'')}" class="btn btn-ghost" style="border:1px solid var(--glass-border); padding:6px 12px;">📞 ${escHtml(l.phone)}</a>` : ''}
                    ${l.whatsapp ? `<a href="javascript:void(0)" onclick="closeModal('listing-details-modal'); openConsultationModal('${l.id}', 'whatsapp', '${escHtml(l.whatsapp.replace(/\D/g,''))}')" class="btn btn-ghost" style="border:1px solid var(--green); color:var(--green); padding:6px 12px;">💬 WhatsApp</a>` : ''}
                    ${l.email ? `<a href="javascript:void(0)" onclick="closeModal('listing-details-modal'); openConsultationModal('${l.id}', 'email', '${escHtml(l.email)}')" class="btn btn-ghost" style="border:1px solid var(--blue); color:var(--blue); padding:6px 12px;">✉️ Email</a>` : ''}
                    ${l.website ? `<a href="${escHtml(l.website.startsWith('http') ? l.website : 'https://'+l.website)}" target="_blank" class="btn btn-primary" style="padding:6px 12px;">🌐 Visit Website</a>` : ''}
                </div>
            `;
            openModal('listing-details-modal');
        };

        window.openMemberDashboard = async function() {
            if (!currentUser) return;
            openModal('member-dashboard-modal');
            
            const role = currentProfile?.role || 'member';
            const statusEl = document.getElementById('md-sub-status');
            if (role === 'admin') {
                statusEl.textContent = 'Administrator';
                statusEl.style.color = 'var(--yellow)';
            } else if (role === 'subscriber') {
                statusEl.textContent = 'Active Subscriber';
                statusEl.style.color = 'var(--green)';
            } else {
                statusEl.textContent = 'Free Member';
                statusEl.style.color = 'white';
            }

            const tbody = document.getElementById('md-listings-tbody');
            tbody.innerHTML = '<tr><td colspan="4" style="text-align:center; padding:20px; color:var(--muted);">Loading...</td></tr>';

            try {
                const { data, error } = await supabase
                    .from('listings')
                    .select('*')
                    .eq('owner_user_id', currentUser.id)
                    .order('created_at', { ascending: false });

                if (error) throw error;

                if (!data || data.length === 0) {
                    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center; padding:20px; color:var(--muted);">You have no active or pending ads.</td></tr>';
                    return;
                }

                tbody.innerHTML = data.map(l => {
                    let statusHtml = '';
                    if (l.status === 'approved') statusHtml = '<span class="listing-badge" style="background:rgba(23,214,111,0.15);color:var(--green);font-size:0.75rem;padding:4px 8px;">Approved</span>';
                    else if (l.status === 'pending') statusHtml = '<span class="listing-badge" style="background:rgba(255,207,51,0.15);color:var(--yellow);font-size:0.75rem;padding:4px 8px;">Pending</span>';
                    else statusHtml = `<span class="listing-badge" style="background:rgba(255,51,51,0.15);color:var(--red);font-size:0.75rem;padding:4px 8px;">${escHtml(l.status)}</span>`;

                    let typeHtml = '';
                    if (l.is_featured) typeHtml = '<span style="color:var(--yellow);font-size:0.85rem;">⭐ Featured</span>';
                    else typeHtml = '<span style="color:var(--muted);font-size:0.85rem;">Basic</span>';

                    return `
                        <tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
                            <td style="padding:12px 10px;"><strong>${escHtml(l.business_name)}</strong></td>
                            <td style="padding:12px 10px;">${statusHtml}</td>
                            <td style="padding:12px 10px;">${typeHtml}</td>
                            <td style="padding:12px 10px;">
                                <a href="javascript:void(0)" onclick="closeModal('member-dashboard-modal'); openListingDetailsModal('${encodeURIComponent(JSON.stringify(l))}');" style="color:var(--blue); font-size:0.85rem;">View</a>
                            </td>
                        </tr>
                    `;
                }).join('');
            } catch (err) {
                console.error(err);
                tbody.innerHTML = '<tr><td colspan="4" style="text-align:center; padding:20px; color:var(--red);">Failed to load listings.</td></tr>';
            }
        };

        window.handleSubscribeClick = function() {
            closeModal('member-dashboard-modal');
            openConsultationModal('subscription', 'email', 'admin@aloejamaica.com');
        };
        // ==========================================
        // INIT
        // ==========================================
        async function init() {
            // NOTE: Tables are pre-created via server-side script. No DB creation in frontend.
            setupSearchListeners();
            setupImagePreview();
            
            // Populate Taxonomy
            if (window.populateCategorySelect) {
                window.populateCategorySelect('search-category');
                window.populateCategorySelect('lf-category');
            }
            window.updateHubLabels = function() {
                const category = document.getElementById('lf-category').value;
                const labels = window.getLabelsForCategory ? window.getLabelsForCategory(category) : {
                    name: 'Business Name*',
                    subcat: 'Subcategory',
                    loc: 'Location*',
                    desc: 'Business Description*'
                };
                
                const nameLabel = document.querySelector('label[for="lf-business-name"]');
                const subcatLabel = document.querySelector('label[for="lf-subcategory"]');
                const locLabel = document.querySelector('label[for="lf-location"]');
                const descLabel = document.querySelector('label[for="lf-description"]');

                if (nameLabel) nameLabel.textContent = labels.name;
                if (subcatLabel) subcatLabel.textContent = labels.subcat;
                if (locLabel) locLabel.textContent = labels.loc;
                if (descLabel) descLabel.textContent = labels.desc;
            };

            const { data: { session } } = await supabase.auth.getSession();
            if (session?.user) {
                await onUserSignedIn(session.user);
            }

            supabase.auth.onAuthStateChange(async (_event, session) => {
                if (session?.user) {
                    await onUserSignedIn(session.user);
                } else {
                    onUserSignedOut();
                }
            });

            await loadListings();
        }

        // ==========================================
        // IMAGE PREVIEW SETUP
        // ==========================================
        function setupImagePreview() {
            const fileInput = document.getElementById('lf-image');
            if (!fileInput) return;
            fileInput.addEventListener('change', () => {
                const file = fileInput.files[0];
                const errEl = document.getElementById('lf-image-error');
                const preview = document.getElementById('lf-image-preview');
                const previewImg = document.getElementById('lf-image-preview-img');
                errEl.style.display = 'none';
                preview.style.display = 'none';
                if (!file) return;
                // Validate type
                const allowed = ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];
                if (!allowed.includes(file.type)) {
                    errEl.textContent = 'Please upload a JPG, PNG, or WebP image.';
                    errEl.style.display = 'block';
                    fileInput.value = '';
                    return;
                }
                // Validate size (5MB)
                if (file.size > 5 * 1024 * 1024) {
                    errEl.textContent = 'Image must be under 5MB.';
                    errEl.style.display = 'block';
                    fileInput.value = '';
                    return;
                }
                // Show preview
                const reader = new FileReader();
                reader.onload = (e) => {
                    previewImg.src = e.target.result;
                    preview.style.display = 'block';
                };
                reader.readAsDataURL(file);
            });
        }

        // [REMOVED: ensureTablesExist — table creation must never run in the browser]

        // ==========================================
        // AUTH: SIGN IN
        // ==========================================
        async function onUserSignedIn(user) {
            currentUser = user;
            const { data: profile } = await supabase
                .from('profiles')
                .select('*')
                .eq('id', user.id)
                .single();

            currentProfile = profile;

            // If no profile row, create one
            if (!profile) {
                const { data: newProfile } = await supabase
                    .from('profiles')
                    .insert({
                        id: user.id,
                        email: user.email,
                        full_name: user.user_metadata?.full_name || '',
                        role: 'member',
                        subscription_status: 'inactive'
                    })
                    .select()
                    .single();
                currentProfile = newProfile;
            }

            updateSidebarLoggedIn();
            await updateNetworkStats();
            updateWhatsAppLink();
            // Show admin panel link if admin
            const adminLink = document.getElementById('admin-panel-link');
            if (adminLink && currentProfile?.role === 'admin') {
                adminLink.style.display = 'block';
            }
            // Reload listings so user can see their own
            await loadListings();
            // Close auth modal if open
            closeModal('auth-modal');
        }

        // ==========================================
        // AUTH: SIGN OUT
        // ==========================================
        function onUserSignedOut() {
            currentUser = null;
            currentProfile = null;
            updateSidebarLoggedOut();
            updateNetworkStatsLocked();
            updateWhatsAppLink();
            loadListings();
        }

        // ==========================================
        // SIDEBAR: UPDATE UI
        // ==========================================
        function updateSidebarLoggedIn() {
            document.getElementById('sidebar-auth-loggedout').style.display = 'none';
            document.getElementById('sidebar-auth-loggedin').style.display = 'block';
            document.getElementById('member-dashboard-nav-btn').style.display = 'inline-block';

            const name = currentProfile?.full_name || currentUser?.email?.split('@')[0] || 'Member';
            const email = currentUser?.email || '';
            const role = currentProfile?.role || 'member';
            const initial = name.charAt(0).toUpperCase();

            document.getElementById('user-avatar-initial').textContent = initial;
            document.getElementById('user-display-name').textContent = name;
            document.getElementById('user-display-email').textContent = email;
            document.getElementById('user-role-badge').textContent =
                role === 'admin' ? '🛡️ Admin' : role === 'subscriber' ? '⭐ Subscriber' : 'Member';
        }

        function updateSidebarLoggedOut() {
            document.getElementById('sidebar-auth-loggedin').style.display = 'none';
            document.getElementById('sidebar-auth-loggedout').style.display = 'block';
            document.getElementById('member-dashboard-nav-btn').style.display = 'none';
        }

        // ==========================================
        // NETWORK STATS — direct DB querying
        // ==========================================
        async function updateNetworkStats() {
            if (!currentUser) {
                updateNetworkStatsLocked();
                return;
            }

            document.getElementById('stats-locked').style.display = 'none';
            document.getElementById('stats-unlocked').style.display = 'flex';
            document.getElementById('stats-unlocked').style.flexDirection = 'column';

            try {
                const role = currentProfile?.role;
                const [{ count: activeListings }, { count: totalMembers }, { count: yourListings }] = await Promise.all([
                    supabase.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'approved'),
                    supabase.from('profiles').select('*', { count: 'exact', head: true }),
                    supabase.from('listings').select('*', { count: 'exact', head: true }).eq('owner_user_id', currentUser.id)
                ]);

                document.getElementById('stat-members').textContent = totalMembers ?? '—';
                document.getElementById('stat-listings').textContent = activeListings ?? '—';
                document.getElementById('stat-your-listings').textContent = yourListings ?? '0';

                if (role === 'admin') {
                    document.getElementById('stat-pending-row').style.display = 'flex';
                    const { count: pendingListings } = await supabase.from('listings').select('*', { count: 'exact', head: true }).eq('status', 'pending');
                    document.getElementById('stat-pending').textContent = pendingListings ?? '0';
                }
            } catch (err) {
                console.warn('Stats error:', err.message);
                updateNetworkStatsLocked();
            }
        }

        function updateNetworkStatsLocked() {
            document.getElementById('stats-locked').style.display = 'block';
            document.getElementById('stats-unlocked').style.display = 'none';
        }


        // ==========================================
        // SEARCH
        // ==========================================
        function setupSearchListeners() {
            const inputs = ['search-keyword', 'search-location', 'search-category'];
            inputs.forEach(id => {
                const el = document.getElementById(id);
                if (el) {
                    el.addEventListener('keydown', (e) => {
                        if (e.key === 'Enter') performSearch();
                    });
                    // For selects, trigger on change too
                    if (el.tagName === 'SELECT') {
                        el.addEventListener('change', performSearch);
                    }
                }
            });
        }

        function clearCategoryFilterUIOnly() {
            activeCategory = null;
            document.getElementById('search-category').value = '';
            document.querySelectorAll('.cat-card').forEach(c => c.classList.remove('active'));
            document.getElementById('active-filter-bar').classList.remove('visible');
            document.getElementById('featured-section-title').textContent = 'Featured Listings';
        }

        async function performSearch() {
            const keyword = document.getElementById('search-keyword').value.trim();
            const location = document.getElementById('search-location').value;
            const category = document.getElementById('search-category').value;

            if (category) {
                // If they explicitly chose a dropdown category
                if (category !== activeCategory) {
                    activeCategory = category;
                    syncCategoryCards(category);
                    showActiveFilterBar(category);
                }
            } else if (keyword || location) {
                // If no dropdown category, but they entered text/location, clear the card filter
                if (activeCategory) {
                    clearCategoryFilterUIOnly();
                }
            }

            listingsOffset = 0;
            await loadListings({ keyword, location, category: document.getElementById('search-category').value });
            scrollToResults();
        }

        function scrollToResults() {
            document.getElementById('services').scrollIntoView({ behavior: 'smooth', block: 'start' });
        }

        // ==========================================
        // CATEGORY FILTER
        // ==========================================
        function filterByCategory(category, el) {
            if (activeCategory === category) {
                clearCategoryFilter();
                return;
            }

            activeCategory = category;
            document.getElementById('search-category').value = '';
            syncCategoryCards(category);
            showActiveFilterBar(category);
            listingsOffset = 0;
            loadListings({ category });
            scrollToResults();
        }

        window.scrollCategories = function(direction) {
            const container = document.getElementById('categories-grid');
            const scrollAmount = 200;
            container.scrollBy({ left: scrollAmount * direction, behavior: 'smooth' });
        };

        function syncCategoryCards(category) {
            document.querySelectorAll('.cat-card').forEach(c => {
                if (c.dataset.category === category) {
                    c.classList.add('active');
                } else {
                    c.classList.remove('active');
                }
            });
        }

        function showActiveFilterBar(category) {
            const labels = {
                services: 'Services', rooms: 'Rooms & Venue', farming: 'Farming',
                retail: 'Retail & Wholesale', food: 'Food & Beverage', events: 'Events & Entertainment', jobs: 'Jobs & Careers'
            };
            const bar = document.getElementById('active-filter-bar');
            document.getElementById('active-filter-label').textContent = labels[category] || category;
            bar.classList.add('visible');
            document.getElementById('featured-section-title').textContent = `Results: ${labels[category] || category}`;
        }

        function clearCategoryFilter() {
            activeCategory = null;
            document.getElementById('search-category').value = '';
            document.querySelectorAll('.cat-card').forEach(c => c.classList.remove('active'));
            document.getElementById('active-filter-bar').classList.remove('visible');
            document.getElementById('featured-section-title').textContent = 'Featured Listings';
            listingsOffset = 0;
            loadListings();
        }

        // ==========================================
        // CATEGORY GROUP MAPPING
        // Maps each card category to all DB categories it covers
        // ==========================================
        const CATEGORY_GROUPS = {
            services: ['SERVICES'],
            rooms:    ['ROOMS & VENUE - RENTALS AND REAL ESTATES SALES'],
            farming:  ['FARMING'],
            retail:   ['RETAIL & WHOLESALE TRADE'],
            food:     ['FOOD & BEVERAGE'],
            events:   ['EVENTS & ENTERTAINMENT'],
            jobs:     ['JOBS & CAREERS']
        };

        function getCategoryFilter(category) {
            // If it's a card category (has a group), use the full group
            const group = CATEGORY_GROUPS[category];
            return group || [category]; // Return group array or single category
        }

        // ==========================================
        // LOAD LISTINGS
        // ==========================================
        async function loadListings(filters = {}) {
            showListingsLoading();

            const keyword = filters.keyword ?? document.getElementById('search-keyword').value.trim();
            const location = filters.location ?? document.getElementById('search-location').value;
            const rawCategory = filters.category ?? activeCategory ?? '';
            const categoryList = rawCategory ? getCategoryFilter(rawCategory) : [];

            try {
                // Helper: apply all filters to a query
                function applyFilters(q) {
                    // Keyword: search across name, description, subcategory, location
                    if (keyword) {
                        const kw = `*${keyword}*`;
                        q = q.or(`business_name.ilike.${kw},description.ilike.${kw},subcategory.ilike.${kw},location.ilike.${kw}`);
                    }
                    // Location: ilike partial match
                    if (location) {
                        q = q.ilike('location', `%${location}%`);
                    }
                    // Category: OR across the group
                    if (categoryList.length === 1) {
                        q = q.eq('category', categoryList[0]);
                    } else if (categoryList.length > 1) {
                        q = q.in('category', categoryList);
                    }
                    return q;
                }

                // Featured query: approved + featured flag
                let featuredQuery = supabase
                    .from('listings')
                    .select('*')
                    .eq('status', 'approved')
                    .eq('is_featured', true);
                featuredQuery = applyFilters(featuredQuery);
                featuredQuery = featuredQuery.order('created_at', { ascending: false }).limit(5);

                // All-listings base query
                let allBase = supabase.from('listings').select('*', { count: 'exact' });
                // Visibility: approved OR own listings if logged in
                if (currentUser) {
                    allBase = allBase.or(`status.eq.approved,owner_user_id.eq.${currentUser.id}`);
                } else {
                    allBase = allBase.eq('status', 'approved');
                }
                let allQuery = applyFilters(allBase);
                allQuery = allQuery.order('is_featured', { ascending: false })
                                   .order('created_at', { ascending: false })
                                   .range(listingsOffset, listingsOffset + LISTINGS_PER_PAGE - 1);

                const [featuredResult, allResult] = await Promise.all([featuredQuery, allQuery]);

                const featured = featuredResult.data || [];
                const all = allResult.data || [];
                totalListingsCount = allResult.count || 0;

                renderFeaturedListings(featured, all);
                renderClassifiedsTable(all, allResult.count);
                updateLoadMoreButton();

            } catch (err) {
                console.error('Error loading listings:', err);
                renderFeaturedListings([], []);
                renderClassifiedsTable([], 0);
            }
        }

        async function loadMoreListings() {
            listingsOffset += LISTINGS_PER_PAGE;

            const keyword = document.getElementById('search-keyword').value.trim();
            const location = document.getElementById('search-location').value;
            const rawCategory = activeCategory || '';
            const categoryList = rawCategory ? getCategoryFilter(rawCategory) : [];

            let query = supabase.from('listings').select('*', { count: 'exact' });
            if (currentUser) {
                query = query.or(`status.eq.approved,owner_user_id.eq.${currentUser.id}`);
            } else {
                query = query.eq('status', 'approved');
            }

            if (keyword) {
                const kw = `*${keyword}*`;
                query = query.or(`business_name.ilike.${kw},description.ilike.${kw},subcategory.ilike.${kw},location.ilike.${kw}`);
            }
            if (location) query = query.ilike('location', `%${location}%`);
            if (categoryList.length === 1) {
                query = query.eq('category', categoryList[0]);
            } else if (categoryList.length > 1) {
                query = query.in('category', categoryList);
            }

            query = query.order('is_featured', { ascending: false })
                         .order('created_at', { ascending: false })
                         .range(listingsOffset, listingsOffset + LISTINGS_PER_PAGE - 1);

            const { data, count } = await query;
            totalListingsCount = count || totalListingsCount;

            // Append to existing table
            const tbody = document.getElementById('classifieds-tbody');
            if (data && data.length > 0) {
                data.forEach(l => {
                    tbody.insertAdjacentHTML('beforeend', buildTableRow(l));
                });
            }

            updateLoadMoreButton();
        }

        function updateLoadMoreButton() {
            const btn = document.getElementById('load-more-btn');
            const currentTotal = listingsOffset + LISTINGS_PER_PAGE;
            if (totalListingsCount > currentTotal) {
                btn.style.display = 'inline';
                btn.textContent = `More Listings (${totalListingsCount - currentTotal} remaining)`;
            } else {
                btn.style.display = 'none';
            }
        }

        // ==========================================
        // RENDER LISTINGS
        // ==========================================
        function showListingsLoading() {
            const container = document.getElementById('featured-listings-container');
            container.innerHTML = [1,2,3].map(() => `
                <div class="listing-skeleton">
                    <div>
                        <div class="skel-line" style="width:70%"></div>
                        <div class="skel-line" style="width:50%"></div>
                    </div>
                    <div>
                        <div class="skel-line" style="width:90%"></div>
                        <div class="skel-line" style="width:60%"></div>
                    </div>
                    <div>
                        <div class="skel-line" style="width:80%"></div>
                        <div class="skel-line" style="width:60%"></div>
                    </div>
                </div>
            `).join('');
            document.getElementById('classifieds-tbody').innerHTML =
                `<tr><td colspan="4" style="text-align:center;padding:30px;color:var(--muted);">Loading...</td></tr>`;
        }

        function renderFeaturedListings(featured, fallback) {
            const container = document.getElementById('featured-listings-container');
            const listings = featured.length > 0 ? featured : fallback.slice(0, 5);

            if (listings.length === 0) {
                container.innerHTML = `
                    <div class="empty-state">
                        <div class="empty-icon">🔍</div>
                        <h4>No listings found for this search.</h4>
                        <p>Try adjusting your keywords, location, or category filter.</p>
                    </div>`;
                return;
            }

            container.innerHTML = listings.map(l => {
                const lJson = encodeURIComponent(JSON.stringify(l));
                return `
                <div class="listing-row" style="cursor: pointer;" onclick="openListingDetailsModal('${lJson}')">
                    ${l.image_url 
                        ? `<img src="${escHtml(l.image_url)}" class="listing-image" alt="Logo">` 
                        : `<div class="listing-image" style="display: flex; align-items: center; justify-content: center; color: var(--muted); font-size: 2.5rem;">🏢</div>`}
                    <div class="listing-details">
                        <div style="display: flex; align-items: center; gap: 10px;">
                            <h4 style="margin: 0; font-size: 1.3rem;">${escHtml(l.business_name)}</h4>
                            ${l.is_featured ? '<span class="listing-badge badge-featured">⭐ Featured</span>' : ''}
                            ${l.status === 'pending' ? '<span class="listing-badge" style="background:rgba(255,207,51,0.15);color:var(--yellow);">⏳ Pending</span>' : ''}
                        </div>
                        <span style="font-size: 0.9rem; color: var(--muted);">${escHtml(formatLocation(l.location))}${l.category ? ' · <span style="color:var(--green);font-weight:600;">' + formatCategory(l.category) + '</span>' : ''}</span>
                        <p style="margin: 4px 0 0 0; font-size: 0.95rem; line-height: 1.5; color: #ddd;">
                            <strong>${escHtml(l.subcategory || '')}</strong> ${l.description ? ' - ' + escHtml(l.description.slice(0, 160)) + (l.description.length > 160 ? '…' : '') : ''}
                        </p>
                    </div>
                    <div class="listing-contact">
                        ${l.phone ? `<span style="font-size:0.95rem; font-weight:600; margin-bottom: 4px;">📞 ${escHtml(l.phone)}</span>` : ''}
                        ${l.email ? `<a href="javascript:void(0)" onclick="event.stopPropagation(); openConsultationModal('${l.id}', 'email', '${escHtml(l.email)}')" class="btn btn-ghost" style="padding: 6px 16px; font-size: 0.85rem; border-color: rgba(255,255,255,0.1); width: 100%; text-align: center;">Email</a>` : ''}
                        ${l.website ? `<a href="${escHtml(l.website)}" target="_blank" rel="noopener" onclick="event.stopPropagation();" class="btn btn-ghost" style="padding: 6px 16px; font-size: 0.85rem; border-color: rgba(255,255,255,0.1); width: 100%; text-align: center;">Website</a>` : ''}
                        ${l.whatsapp ? `<a href="javascript:void(0)" onclick="event.stopPropagation(); openConsultationModal('${l.id}', 'whatsapp', '${escHtml(l.whatsapp.replace(/\D/g,''))}')" class="btn btn-primary" style="padding: 6px 16px; font-size: 0.85rem; width: 100%; text-align: center;">WhatsApp</a>` : ''}
                    </div>
                </div>
            `;
            }).join('');
        }

        function buildTableRow(l) {
            const lJson = encodeURIComponent(JSON.stringify(l));
            return `
                <tr style="cursor: pointer;" onclick="openListingDetailsModal('${lJson}')">
                    <td style="display:flex; align-items:center; gap:12px;">
                        ${l.image_url ? `<img src="${escHtml(l.image_url)}" alt="Logo" style="width: 48px; height: 48px; object-fit: cover; border-radius: 6px; flex-shrink: 0; background: var(--glass-bg); border: 1px solid var(--glass-border);">` : `<div style="width: 48px; height: 48px; border-radius: 6px; flex-shrink: 0; background: var(--glass-bg); border: 1px solid var(--glass-border); display: flex; align-items: center; justify-content: center; color: var(--muted); font-size: 1.2rem;">🏢</div>`}
                        <div>
                            <strong>${escHtml(l.business_name)}</strong>${l.status === 'pending' ? ' <span style="font-size:0.7rem;color:var(--yellow);">(pending)</span>' : ''}
                        </div>
                    </td>
                    <td>${escHtml(l.subcategory || formatCategory(l.category) || '—')}</td>
                    <td>${escHtml(formatLocation(l.location))}</td>
                    <td>${l.email ? `<a href="javascript:void(0)" onclick="event.stopPropagation(); openConsultationModal('${l.id}', 'email', '${escHtml(l.email)}')" style="color:var(--blue);">Email</a>` : l.phone ? escHtml(l.phone) : '—'}</td>
                </tr>`;
        }

        function renderClassifiedsTable(listings, count) {
            const tbody = document.getElementById('classifieds-tbody');

            if (!listings || listings.length === 0) {
                tbody.innerHTML = `<tr><td colspan="4" style="text-align:center;padding:40px;color:var(--muted);">No listings found for this search.</td></tr>`;
                return;
            }

            tbody.innerHTML = listings.map(l => buildTableRow(l)).join('');
        }

        // ==========================================
        // AUTH HANDLERS
        // ==========================================
        async function handleLogin() {
            const email = document.getElementById('modal-login-email').value.trim();
            const password = document.getElementById('modal-login-password').value;
            const errBox = document.getElementById('login-error');

            errBox.classList.remove('show');
            setLoading('login-btn-text', 'login-spinner', true);

            if (!email || !password) {
                showErrBox(errBox, 'Please enter your email and password.');
                setLoading('login-btn-text', 'login-spinner', false);
                return;
            }

            const { error } = await supabase.auth.signInWithPassword({ email, password });
            setLoading('login-btn-text', 'login-spinner', false);

            if (error) {
                showErrBox(errBox, error.message || 'Login failed. Please check your credentials.');
            } else {
                showToast('Welcome back! You are now logged in.', 'success');
            }
        }

        async function handleRegister() {
            const name = document.getElementById('modal-reg-name').value.trim();
            const email = document.getElementById('modal-reg-email').value.trim();
            const password = document.getElementById('modal-reg-password').value;
            const confirmPassword = document.getElementById('modal-reg-password-confirm').value;
            const errBox = document.getElementById('register-error');
            const successBox = document.getElementById('register-success');

            errBox.classList.remove('show');
            successBox.classList.remove('show');
            setLoading('reg-btn-text', 'reg-spinner', true);

            if (!name || !email || !password || !confirmPassword) {
                showErrBox(errBox, 'Please fill in all fields.');
                setLoading('reg-btn-text', 'reg-spinner', false);
                return;
            }
            if (password !== confirmPassword) {
                showErrBox(errBox, 'Passwords do not match.');
                setLoading('reg-btn-text', 'reg-spinner', false);
                return;
            }
            if (password.length < 6) {
                showErrBox(errBox, 'Password must be at least 6 characters.');
                setLoading('reg-btn-text', 'reg-spinner', false);
                return;
            }

            const { data, error } = await supabase.auth.signUp({
                email,
                password,
                options: { data: { full_name: name } }
            });
            setLoading('reg-btn-text', 'reg-spinner', false);

            if (error) {
                showErrBox(errBox, error.message || 'Registration failed. Please try again.');
            } else {
                successBox.textContent = 'Account created! Please check your email to confirm your address, then login.';
                successBox.classList.add('show');
                document.getElementById('modal-reg-name').value = '';
                document.getElementById('modal-reg-email').value = '';
                document.getElementById('modal-reg-password').value = '';
            }
        }

        async function handleForgotPassword() {
            const email = document.getElementById('modal-forgot-email').value.trim();
            const errBox = document.getElementById('forgot-error');
            const successBox = document.getElementById('forgot-success');

            errBox.classList.remove('show');
            successBox.classList.remove('show');
            setLoading('forgot-btn-text', 'forgot-spinner', true);

            if (!email) {
                showErrBox(errBox, 'Please enter your email address.');
                setLoading('forgot-btn-text', 'forgot-spinner', false);
                return;
            }

            const { error } = await supabase.auth.resetPasswordForEmail(email, {
                redirectTo: window.location.origin + '/ajm-advertising-hub.html'
            });
            setLoading('forgot-btn-text', 'forgot-spinner', false);

            if (error) {
                showErrBox(errBox, error.message || 'Could not send reset email. Please try again.');
            } else {
                successBox.textContent = 'Reset link sent! Check your email inbox (and spam folder).';
                successBox.classList.add('show');
                document.getElementById('modal-forgot-email').value = '';
            }
        }

        async function handleSidebarLogin() {
            const email = document.getElementById('sidebar-email').value.trim();
            const password = document.getElementById('sidebar-password').value;
            const errBox = document.getElementById('sidebar-login-error');

            errBox.classList.remove('show');
            setLoading('sidebar-login-text', 'sidebar-login-spinner', true);

            if (!email || !password) {
                showErrBox(errBox, 'Enter your email and password.');
                setLoading('sidebar-login-text', 'sidebar-login-spinner', false);
                return;
            }

            const { error } = await supabase.auth.signInWithPassword({ email, password });
            setLoading('sidebar-login-text', 'sidebar-login-spinner', false);

            if (error) {
                showErrBox(errBox, error.message || 'Login failed.');
            } else {
                document.getElementById('sidebar-email').value = '';
                document.getElementById('sidebar-password').value = '';
                showToast('Welcome back! You are now logged in.', 'success');
            }
        }

        async function handleLogout() {
            await supabase.auth.signOut();
            showToast('You have been signed out.', 'info');
        }

        // ==========================================
        // POST LISTING
        // ==========================================
        function handlePostListingClick() {
            if (currentUser) {
                openModal('post-listing-modal');
            } else {
                openModal('post-login-prompt-modal');
            }
        }

        async function handleListingSubmit(e) {
            e.preventDefault();
            const errBox = document.getElementById('listing-form-error');
            const successBox = document.getElementById('listing-form-success');
            errBox.classList.remove('show');
            successBox.classList.remove('show');

            if (!currentUser) {
                showErrBox(errBox, 'You must be logged in to submit a listing.');
                return;
            }

            const businessName = document.getElementById('lf-business-name').value.trim();
            const category = document.getElementById('lf-category').value;
            const subcategory = document.getElementById('lf-subcategory').value.trim();
            const description = document.getElementById('lf-description').value.trim();
            const location = document.getElementById('lf-location').value;
            const phone = document.getElementById('lf-phone').value.trim();
            const whatsapp = document.getElementById('lf-whatsapp').value.trim();
            const email = document.getElementById('lf-email').value.trim();
            const website = document.getElementById('lf-website').value.trim();
            const notes = document.getElementById('lf-notes').value.trim();
            const listingType = document.querySelector('input[name="listing_type"]:checked')?.value || 'basic';
            const imageFile = document.getElementById('lf-image')?.files?.[0] || null;

            if (!businessName || !category || !description || !location) {
                showErrBox(errBox, 'Please fill in all required fields: Business Name, Category, Description, and Location.');
                return;
            }

            setLoading('listing-submit-text', 'listing-submit-spinner', true);

            // Upload image if provided
            let imageUrl = null;
            if (imageFile) {
                const ext = imageFile.name.split('.').pop().toLowerCase();
                const filePath = `${currentUser.id}/${Date.now()}.${ext}`;
                const { data: uploadData, error: uploadError } = await supabase.storage
                    .from('listing-images')
                    .upload(filePath, imageFile, { cacheControl: '3600', upsert: false });

                if (uploadError) {
                    setLoading('listing-submit-text', 'listing-submit-spinner', false);
                    showErrBox(errBox, 'Image upload failed: ' + (uploadError.message || 'Please try again.'));
                    return;
                }
                const { data: urlData } = supabase.storage.from('listing-images').getPublicUrl(filePath);
                imageUrl = urlData?.publicUrl || null;
            }

            const { error } = await supabase.from('listings').insert({
                business_name: businessName,
                category,
                subcategory,
                description,
                location,
                contact_phone: phone || null,
                whatsapp: whatsapp || null,
                email: email || null,
                website: website || null,
                image_url: imageUrl,
                extra_notes: notes || null,
                listing_type: listingType,
                status: 'pending',
                owner_user_id: currentUser.id
            });

            setLoading('listing-submit-text', 'listing-submit-spinner', false);

            if (error) {
                showErrBox(errBox, error.message || 'Failed to submit listing. Please try again.');
            } else {
                successBox.textContent = '✅ Your listing has been submitted for review. It will appear publicly once approved by an admin.';
                successBox.classList.add('show');
                document.getElementById('listing-form').reset();
                document.getElementById('lf-image-preview').style.display = 'none';
                showToast('Listing submitted! Pending admin approval.', 'success');
                setTimeout(() => closeModal('post-listing-modal'), 4000);
            }
        }

        // ==========================================
        // WHATSAPP
        // ==========================================
        function updateWhatsAppLink() {
            // Keep FAB generic or maybe we can make it trackable too later
        }

        function handleWhatsAppClick() {
            const message = "Hi! I'm interested in advertising my business on AJM Advertising Hub.";
            const url = `https://wa.me/${WHATSAPP_NUMBER}?text=${encodeURIComponent(message)}`;
            window.open(url, '_blank');
        }

        // CONSULTATION TRACKING
        window.openConsultationModal = function(listingId, source, target) {
            document.getElementById('cons-listing-id').value = listingId;
            document.getElementById('cons-source').value = source;
            document.getElementById('cons-target').value = target;
            document.getElementById('cons-name').value = '';
            document.getElementById('cons-phone').value = '';
            document.getElementById('cons-email').value = '';
            document.getElementById('consultation-modal').classList.add('open');
        };

        window.closeConsultationModal = function() {
            document.getElementById('consultation-modal').classList.remove('open');
        };

        window.submitConsultation = async function() {
            const listingId = document.getElementById('cons-listing-id').value;
            const source = document.getElementById('cons-source').value;
            const target = document.getElementById('cons-target').value;
            const name = document.getElementById('cons-name').value.trim();
            const phone = document.getElementById('cons-phone').value.trim();
            const email = document.getElementById('cons-email').value.trim();

            if (!name || !phone) {
                showToast('Please provide your name and phone number.', 'error');
                return;
            }

            const btnText = document.getElementById('cons-submit-text');
            const spinner = document.getElementById('cons-spinner');
            btnText.style.display = 'none';
            spinner.style.display = 'inline-block';

            // Insert to Supabase
            const { error } = await supabase.from('consultations').insert([{
                listing_id: listingId,
                customer_name: name,
                phone: phone,
                email: email,
                source: source
            }]);

            btnText.style.display = 'inline-block';
            spinner.style.display = 'none';

            if (error) {
                console.error('Error saving consultation:', error);
                showToast('Connection error. Please try again.', 'error');
                return;
            }

            closeConsultationModal();
            showToast('Redirecting...', 'success');

            // Redirect
            if (source === 'whatsapp') {
                window.open(`https://wa.me/${target}?text=Hi, I found your listing on AJM Advertising Hub! My name is ${encodeURIComponent(name)}.`, '_blank');
            } else {
                window.location.href = `mailto:${target}?subject=Inquiry from AJM Hub - ${encodeURIComponent(name)}`;
            }
        };

        // ==========================================
        // MODAL HELPERS
        // ==========================================
        function openModal(id) {
            const modal = document.getElementById(id);
            if (modal) {
                modal.classList.add('open');
                document.body.style.overflow = 'hidden';
            }
        }

        function closeModal(id) {
            const modal = document.getElementById(id);
            if (modal) {
                modal.classList.remove('open');
                document.body.style.overflow = '';
            }
        }

        // Close on backdrop click
        document.querySelectorAll('.modal-overlay').forEach(overlay => {
            overlay.addEventListener('click', (e) => {
                if (e.target === overlay) closeModal(overlay.id);
            });
        });

        // Close on Escape
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                document.querySelectorAll('.modal-overlay.open').forEach(m => closeModal(m.id));
            }
        });

        // ==========================================
        // AUTH TAB SWITCHER
        // ==========================================
        function switchAuthTab(tab) {
            ['login', 'register', 'forgot'].forEach(t => {
                document.getElementById(`auth-panel-${t}`).style.display = t === tab ? 'block' : 'none';
                const tabEl = document.getElementById(`tab-${t}`);
                if (tabEl) {
                    tabEl.classList.toggle('active', t === tab);
                    tabEl.setAttribute('aria-selected', t === tab ? 'true' : 'false');
                }
            });
        }

        // ==========================================
        // UTILITY HELPERS
        // ==========================================
        function setLoading(textId, spinnerId, isLoading) {
            const txt = document.getElementById(textId);
            const sp = document.getElementById(spinnerId);
            if (txt) txt.style.display = isLoading ? 'none' : 'inline';
            if (sp) sp.classList.toggle('show', isLoading);
        }

        function showErrBox(el, msg) {
            el.textContent = msg;
            el.classList.add('show');
        }

        function showToast(msg, type = 'info') {
            const toast = document.getElementById('toast');
            const icons = { success: '✅', error: '❌', info: 'ℹ️' };
            toast.className = `toast toast-${type} show`;
            toast.innerHTML = `<span class="toast-icon">${icons[type]}</span><span>${msg}</span>`;
            clearTimeout(toast._timer);
            toast._timer = setTimeout(() => {
                toast.classList.remove('show');
            }, 5000);
        }

        function escHtml(str) {
            if (!str) return '';
            return String(str)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;');
        }

        function formatLocation(loc) {
            if (!loc) return '';
            const map = {
                kingston: 'Kingston', 'st-andrew': 'St. Andrew', 'st-thomas': 'St. Thomas',
                portland: 'Portland', 'st-mary': 'St. Mary', 'st-ann': 'St. Ann',
                trelawny: 'Trelawny', 'st-james': 'St. James', hanover: 'Hanover',
                westmoreland: 'Westmoreland', 'st-elizabeth': 'St. Elizabeth',
                manchester: 'Manchester', clarendon: 'Clarendon', 'st-catherine': 'St. Catherine',
                islandwide: 'Islandwide'
            };
            return map[loc] || loc;
        }

        function formatCategory(cat) {
            const map = {
                services: 'Services', rooms: 'Rooms & Spaces', farming: 'Farming',
                retail: 'Retail Shopping', food: 'Drink & Eat', health: 'Health & Wellness',
                finance: 'Financial Services', tech: 'Technology', education: 'Education', other: 'Other'
            };
            return map[cat] || cat;
        }

        // ==========================================
        // START
        // ==========================================
        init();
