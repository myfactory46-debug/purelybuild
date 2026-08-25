document.addEventListener('DOMContentLoaded', async () => {
  const urlParams = new URLSearchParams(window.location.search);
  const storeSlug = urlParams.get('store');

  if (!storeSlug) return;

  const supabase = window.supabaseClient;
  if (!supabase) {
    console.error('Supabase client not initialized');
    return;
  }

  try {
    // 1. جلب بيانات المتجر
    const { data: stores, error: storeError } = await supabase
      .from('stores')
      .select('*')
      .eq('slug', storeSlug);

    if (storeError || !stores || stores.length === 0) {
      console.error('Store not found:', storeError);
      return;
    }

    const storeData = stores[0];

    // 2. تحديث عنوان الصفحة واسم المتجر في الهيدر
    document.title = storeData.store_name;
    const storeTitleEl = document.getElementById('store-title');
    if (storeTitleEl) storeTitleEl.textContent = storeData.store_name;

    // 3. جلب منتجات المتجر
    const { data: productsData, error: productsError } = await supabase
      .from('products')
      .select('*')
      .eq('store_id', storeData.id);

    if (productsError) {
      console.error('Error fetching products:', productsError);
      return;
    }

    // 4. تنظيم الواجهة: إخفاء عناصر الـ Landing Page وإظهار محتوى المتجر بشكل مرتب
    const mainContent = document.querySelector('main');
    if (mainContent) {
      // إخفاء كل العناصر داخل الـ main ما عدا حاوية المنتجات
      Array.from(mainContent.children).forEach(child => {
        if (!child.contains(document.getElementById('products-container'))) {
          child.style.display = 'none';
        }
      });
    }

    const container = document.getElementById('products-container');
    if (!container) return;

    // إضافة عنوان ترحيبي للمتجر فوق المنتجات إذا لم يكن موجوداً
    if (!document.getElementById('store-welcome-title')) {
      const welcomeHeader = document.createElement('div');
      welcomeHeader.id = 'store-welcome-title';
      welcomeHeader.className = 'text-center mb-12';
      welcomeHeader.innerHTML = `
        <h1 class="text-4xl font-extrabold text-white mb-3">${storeData.store_name}</h1>
        <p class="text-slate-400 text-lg">Welcome to our official store. Browse our products below.</p>
      `;
      container.parentNode.insertBefore(welcomeHeader, container);
    }

    container.innerHTML = '';

    if (productsData && productsData.length > 0) {
      productsData.forEach(product => {
        const card = document.createElement('div');
        card.className = 'bg-slate-900 border border-slate-800 p-6 rounded-xl text-left shadow-xl hover:border-blue-500/50 transition';
        card.innerHTML = `
          <h3 class="text-xl font-bold text-white mb-2">${product.name}</h3>
          <p class="text-emerald-400 font-semibold text-2xl mb-6">$${product.price}</p>
          <button class="w-full bg-blue-600 hover:bg-blue-500 text-white font-medium py-2.5 px-4 rounded-lg text-sm transition">Buy Now</button>
        `;
        container.appendChild(card);
      });
    } else {
      container.innerHTML = '<p class="text-slate-400 col-span-full text-center py-10">No products available in this store yet.</p>';
    }

  } catch (err) {
    console.error('Unexpected error:', err);
  }
});
