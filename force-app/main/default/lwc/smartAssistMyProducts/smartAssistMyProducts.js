import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMyProducts from '@salesforce/apex/SmartAssistSupportController.getMyProducts';

const GENERIC_ERROR_MESSAGE =
    "We're having trouble loading your products right now. Please try again in a moment, " +
    'or contact support if the issue continues.';

/**
 * smartAssistMyProducts
 *
 * Customer-facing "My Products" page for the SmartAssist 360 Experience
 * Cloud portal. Lists the Assets legitimately owned by the logged-in
 * customer (resolved server-side - the browser never supplies or filters
 * this list) and lets the customer choose one to get AI support for,
 * per the SmartAssist 360 journey:
 *
 *   Login -> My Products -> Select Product/Asset -> Ask AI Support -> ...
 *
 * This is the ONLY place in the SmartAssist 360 portal where the customer
 * selects a product. The Support page (smartAssistSupport) intentionally
 * does not allow product selection.
 *
 * Two ways to hand off the selected Asset to the Support page - use
 * whichever fits how your Experience Cloud site is composed:
 *
 *   1. Same-page composition: a parent component/page listens for the
 *      `productselect` event this component dispatches and swaps in (or
 *      updates) the smartAssistSupport component with the chosen assetId.
 *
 *   2. Separate pages: set the `supportPageName` public property (via
 *      Experience Builder) to the API name of your Support page. This
 *      component will then navigate there via NavigationMixin, passing
 *      assetId as page state. The Support page's own Apex re-validates
 *      ownership of that assetId regardless, so this is a convenience for
 *      wiring pages together - not a security boundary.
 */
export default class SmartAssistMyProducts extends NavigationMixin(LightningElement) {
    // API name of the Experience Cloud page to navigate to when a product is
    // selected (e.g. "Support"). Leave blank to only dispatch the
    // `productselect` event and let a parent component handle navigation /
    // composition itself.
    @api supportPageName;

    isLoading = true;
    products = [];
    errorMessage = '';

    connectedCallback() {
        this.loadProducts();
    }

    async loadProducts() {
        this.isLoading = true;
        this.clearError();
        try {
            const results = await getMyProducts();
            this.products = results.map((product) => ({
                ...product,
                purchaseDateFormatted: this.formatDate(product.purchaseDate),
                statusBadgeClass: this.getStatusBadgeClass(product.status)
            }));
        } catch (error) {
            this.products = [];
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isLoading = false;
        }
    }

    handleSelectProduct(event) {
        const assetId = event.currentTarget.dataset.assetId;
        if (!assetId) {
            return;
        }

        // Let any parent component handle the selection (composition pattern).
        this.dispatchEvent(
            new CustomEvent('productselect', {
                detail: { assetId },
                bubbles: true,
                composed: true
            })
        );

        // Optionally also navigate directly to a configured Support page.
        if (this.supportPageName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: {
                    name: this.supportPageName
                },
                state: {
                    assetId
                }
            });
        }
    }

    get showEmptyState() {
        return !this.isLoading && !this.hasError && this.products.length === 0;
    }

    get showProductGrid() {
        return !this.isLoading && !this.hasError && this.products.length > 0;
    }

    get hasError() {
        return !!this.errorMessage;
    }

    formatDate(dateValue) {
        if (!dateValue) {
            return '—';
        }
        try {
            return new Intl.DateTimeFormat(undefined, {
                year: 'numeric',
                month: 'long',
                day: 'numeric'
            }).format(new Date(dateValue));
        } catch (e) {
            return dateValue;
        }
    }

    getStatusBadgeClass(status) {
        const normalized = (status || '').toLowerCase();
        const base = 'sa-status-badge';
        if (normalized === 'shipped' || normalized === 'installed' || normalized === 'active') {
            return `${base} sa-status-active`;
        }
        return `${base} sa-status-neutral`;
    }

    resolveErrorMessage(error) {
        if (error && error.body) {
            if (typeof error.body.message === 'string' && error.body.message.trim()) {
                return error.body.message;
            }
            if (Array.isArray(error.body) && error.body.length > 0 && error.body[0].message) {
                return error.body[0].message;
            }
        }
        return GENERIC_ERROR_MESSAGE;
    }

    setError(message) {
        this.errorMessage = message || GENERIC_ERROR_MESSAGE;
    }

    clearError() {
        this.errorMessage = '';
    }
}