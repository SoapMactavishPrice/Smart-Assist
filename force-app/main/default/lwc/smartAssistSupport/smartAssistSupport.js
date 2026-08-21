import { LightningElement, api } from 'lwc';
import getAssetContext from '@salesforce/apex/SmartAssistSupportController.getAssetContext';
import getMyAssets from '@salesforce/apex/SmartAssistSupportController.getMyAssets';
import askSmartAssist from '@salesforce/apex/SmartAssistSupportController.askSmartAssist';
import markConversationResolved from '@salesforce/apex/SmartAssistSupportController.markConversationResolved';
import markConversationResolvedNoCase from '@salesforce/apex/SmartAssistSupportController.markConversationResolvedNoCase';
import createSupportCase from '@salesforce/apex/SmartAssistSupportController.createSupportCase';

const CONFIDENCE_THRESHOLD = 85;

// Generic, customer-safe error message. Technical details are intentionally never surfaced.
const GENERIC_ERROR_MESSAGE =
    "We're having trouble processing your request right now. Please try again in a moment, " +
    'or contact support if the issue continues.';

/**
 * smartAssistSupport
 *
 * Customer-facing AI support page for the SmartAssist 360 Experience Cloud portal.
 * This component is intentionally "thin": it manages UI state and delegates all
 * business logic, security enforcement, and AI orchestration to Apex
 * (SmartAssistSupportController / SmartAssistAIService).
 */
export default class SmartAssistSupport extends LightningElement {
    // The selected Asset Id is expected to arrive as a public property, set
    // either via Experience Builder page-level configuration or by the
    // parent "My Products" flow that navigated the customer here. It is
    // never read out of a URL/page-state parameter: those are
    // client-supplied and not a trustworthy way to identify "the Asset this
    // customer is allowed to see" - that determination is made in Apex from
    // the logged-in user's Contact/Account relationship (see
    // resolveAssetForCurrentCustomer / SmartAssistSupportController).
    _assetId;
    hasInitialized = false;

    @api
    get assetId() {
        return this._assetId;
    }
    set assetId(value) {
        this._assetId = value;
        if (value) {
            this.hasInitialized = true;
            this.loadAssetContext();
        }
    }

    connectedCallback() {
        // If no assetId was supplied as a public property by the time the
        // component is connected, fall back to resolving it server-side
        // from the customer's own Account/Contact - never from anything in
        // the URL or page state.
        if (!this.hasInitialized && !this._assetId) {
            this.hasInitialized = true;
            this.resolveAssetForCurrentCustomer();
        }
    }

    // ------------------------------------------------------------------
    // Tracked-like reactive state (plain fields trigger reactivity for
    // primitives/objects reassigned wholesale, which is what we do here)
    // ------------------------------------------------------------------
    isContextLoading = true;
    assetContext;

    questionText = '';
    isAsking = false;
    hasAskedOnce = false;

    aiResult; // { conversationId, responseText, category, subcategory, summary, recommendation, confidenceScore }
    isLowConfidenceProcessing = false;

    satisfactionStage = 'none'; // 'none' | 'initial' | 'createCase' | 'done'
    isSatisfactionProcessing = false;
    resolvedMessage = '';

    caseNumber;
    showCaseConfirmation = false;

    errorMessage = '';

    // ------------------------------------------------------------------
    // Fallback resolution: no assetId was supplied by the caller. Ask Apex
    // for the Assets the logged-in customer actually owns (resolved from
    // User -> Contact -> Account server-side) rather than trusting any
    // client-side identifier. This is a recovery path only - it does not
    // let the customer pick an arbitrary Asset in this component.
    // ------------------------------------------------------------------
    async resolveAssetForCurrentCustomer() {
        this.isContextLoading = true;
        this.clearError();
        try {
            const ownedAssets = await getMyAssets();

            if (ownedAssets.length === 1) {
                // Exactly one product on the account - safe to auto-select.
                this._assetId = ownedAssets[0].assetId;
                await this.loadAssetContext();
            } else if (ownedAssets.length === 0) {
                this.isContextLoading = false;
                this.setError(
                    "We couldn't find any products on your account. Please contact support if you believe this is an error."
                );
            } else {
                // Multiple products - selection belongs on My Products, not here.
                this.isContextLoading = false;
                this.setError('Please go back to My Products and select a product to get support for.');
            }
        } catch (error) {
            this.isContextLoading = false;
            this.setError(this.resolveErrorMessage(error));
        }
    }

    // ------------------------------------------------------------------
    // Load / validate the selected Asset via Apex (server enforces ownership)
    // ------------------------------------------------------------------
    async loadAssetContext() {
        this.isContextLoading = true;
        this.clearError();
        try {
            const result = await getAssetContext({ assetId: this._assetId });
            this.assetContext = {
                ...result,
                purchaseDateFormatted: this.formatDate(result.purchaseDate)
            };
        } catch (error) {
            this.assetContext = undefined;
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isContextLoading = false;
        }
    }

    // ------------------------------------------------------------------
    // Question input
    // ------------------------------------------------------------------
    handleQuestionChange(event) {
        this.questionText = event.detail.value;
    }

    get isAskDisabled() {
        return !this.questionText || !this.questionText.trim() || this.isAsking;
    }

    // ------------------------------------------------------------------
    // Ask SmartAssist
    // ------------------------------------------------------------------
    async handleAskSmartAssist() {
        if (this.isAskDisabled || !this._assetId) {
            return;
        }

        this.isAsking = true;
        this.clearError();
        this.aiResult = undefined;
        this.satisfactionStage = 'none';
        this.showCaseConfirmation = false;
        this.resolvedMessage = '';

        try {
            const response = await askSmartAssist({
                assetId: this._assetId,
                question: this.questionText.trim()
            });

            this.aiResult = {
                conversationId: response.conversationId,
                responseText: response.aiResponse,
                category: response.category,
                subcategory: response.subcategory,
                summary: response.summary,
                recommendation: response.recommendation,
                confidenceScore: response.confidenceScore
            };
            this.hasAskedOnce = true;

            if (this.confidenceScoreNumber >= CONFIDENCE_THRESHOLD) {
                this.satisfactionStage = 'initial';
            } else {
                // Low confidence: skip satisfaction question, auto-create the case.
                this.satisfactionStage = 'none';
                await this.autoCreateCaseForLowConfidence();
            }
        } catch (error) {
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isAsking = false;
        }
    }

    async autoCreateCaseForLowConfidence() {
        this.isLowConfidenceProcessing = true;
        try {
            const caseResult = await createSupportCase({ conversationId: this.aiResult.conversationId });
            this.caseNumber = caseResult.caseNumber;
            this.showCaseConfirmation = true;
        } catch (error) {
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isLowConfidenceProcessing = false;
        }
    }

    // ------------------------------------------------------------------
    // Satisfaction workflow
    // ------------------------------------------------------------------
    async handleSatisfiedYes() {
        this.isSatisfactionProcessing = true;
        this.clearError();
        try {
            await markConversationResolved({ conversationId: this.aiResult.conversationId });
            this.resolvedMessage = "Great! We're glad we could help.";
            this.satisfactionStage = 'done';
        } catch (error) {
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isSatisfactionProcessing = false;
        }
    }

    handleSatisfiedNo() {
        this.satisfactionStage = 'createCase';
    }

    async handleCreateCaseYes() {
        this.isSatisfactionProcessing = true;
        this.clearError();
        try {
            const caseResult = await createSupportCase({ conversationId: this.aiResult.conversationId });
            this.caseNumber = caseResult.caseNumber;
            this.showCaseConfirmation = true;
            this.satisfactionStage = 'done';
        } catch (error) {
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isSatisfactionProcessing = false;
        }
    }

    async handleCreateCaseNo() {
        this.isSatisfactionProcessing = true;
        this.clearError();
        try {
            await markConversationResolvedNoCase({ conversationId: this.aiResult.conversationId });
            this.resolvedMessage = 'Your conversation has been marked as resolved.';
            this.satisfactionStage = 'done';
        } catch (error) {
            this.setError(this.resolveErrorMessage(error));
        } finally {
            this.isSatisfactionProcessing = false;
        }
    }

    // ------------------------------------------------------------------
    // Derived getters for template
    // ------------------------------------------------------------------
    get showMainContent() {
        return !this.isContextLoading && !!this.assetContext;
    }

    get showQuestionCard() {
        return this.showMainContent && !this.isAsking;
    }

    get showResponseCard() {
        return !!this.aiResult && !this.isAsking;
    }

    get confidenceScoreNumber() {
        return this.aiResult && this.aiResult.confidenceScore != null ? Number(this.aiResult.confidenceScore) : 0;
    }

    get confidencePercentDisplay() {
        return `${Math.round(this.confidenceScoreNumber)}%`;
    }

    get confidenceBadgeClass() {
        const base = 'sa-confidence-badge';
        return this.confidenceScoreNumber >= CONFIDENCE_THRESHOLD
            ? `${base} sa-confidence-high`
            : `${base} sa-confidence-low`;
    }

    get confidenceBarClass() {
        const base = 'sa-progress-fill';
        return this.confidenceScoreNumber >= CONFIDENCE_THRESHOLD
            ? `${base} sa-progress-fill-high`
            : `${base} sa-progress-fill-low`;
    }

    get confidenceBarStyle() {
        const pct = Math.max(0, Math.min(100, this.confidenceScoreNumber));
        return `width: ${pct}%;`;
    }

    get statusBadgeClass() {
        const status = (this.assetContext && this.assetContext.status) || '';
        const normalized = status.toLowerCase();
        if (normalized === 'shipped' || normalized === 'installed' || normalized === 'active') {
            return 'sa-status-badge sa-status-active';
        }
        return 'sa-status-badge sa-status-neutral';
    }

    get showSatisfactionCard() {
        return this.satisfactionStage === 'initial' || this.satisfactionStage === 'createCase';
    }

    get showInitialSatisfactionQuestion() {
        return this.satisfactionStage === 'initial' && !this.isSatisfactionProcessing;
    }

    get showCreateCaseQuestion() {
        return this.satisfactionStage === 'createCase' && !this.isSatisfactionProcessing;
    }

    get showResolvedConfirmation() {
        return this.satisfactionStage === 'done' && !!this.resolvedMessage && !this.showCaseConfirmation;
    }

    get hasError() {
        return !!this.errorMessage;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
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

    // Apex throws AuraHandledException with a customer-safe message for all
    // expected error conditions. Anything else (unexpected shape) falls back
    // to a generic message so no technical detail ever reaches the customer.
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
