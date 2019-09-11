# frozen_string_literal: true

class CampaignMatch
  def initialize(campaign, influencer)
    @campaign = campaign
    @influencer = influencer
  end

  def self.available_campaigns(influencer)
    campaigns = Campaign.active
                        .where('campaigns.min_score <= ? and campaigns.max_score >= ?',
                               influencer.adjusted_score, influencer.adjusted_score)
                        .where("campaigns.exclude = '{}' OR ? != ANY (campaigns.exclude)", influencer.status)
                        .where.not(id: influencer.offers.pluck(:campaign_id))
    campaigns.select { |campaign| CampaignMatch.new(campaign, influencer).valid? }
  end

  def self.available_influencers(campaign)
    influencers = Instagramer.verified.subscribed.where(score: campaign.min_score..campaign.max_score)
    influencers.select { |influencer| CampaignMatch.new(campaign, influencer).valid? }
  end

  def self.if_matched_with_any_location?(instagramer, locations)
    locations.collect { |location| Location.within?(location, instagramer.latlon) }.include? true
  end

  # [MLN] Remove after confirming previous location logic fix
  def self.if_within_location?(instagramer, location)
    zip = location[0][:zip_code]
    loc_distance = location[0][:distance]

    return false if zip.blank? || !instagramer.geocoded?

    point1 = Geocoder.coordinates(zip)
    point2 = instagramer.latlon
    distance = Geocoder::Calculations.distance_between(point1, point2)

    distance < loc_distance.to_f
  end

  def self.filter_influencers_based_on_location(influencers, locations)
    influencers.select { |instagramer| if_matched_with_any_location?(instagramer, locations) }
  end

  def self.matched_influencers_based_on_campaign_categories(influencers, campaign_categories)
    influencers.select { |inst| inst.instagramer_categories.where(category_id: campaign_categories).present? }
  end

  # [MLN] Remove after confirming previous location logic fix
  def self.matched_influencers_on_location(influencers, location)
    influencers = influencers.select(&:geocoded?)
    influencers.select { |instagramer| if_within_location?(instagramer, location) }
  end

  def self.reputation_criteria(reputation, unreviewed)
    case reputation
    when 'unreviewed' then %w[unreviewed]
    when 'safe' then %w[safe]
    when 'appropriate' then %w[safe appropriate]
    when 'non-pc' then %w[safe appropriate non-pc]
    end.unshift(unreviewed).compact
  end

  def self.show_available_influencers(criteria)
    popularity = criteria[:popularity].split(' ')
    campaign_categories = criteria[:campaign_categories].reject(&:blank?)

    @influencers = Instagramer.verified.subscribed

    unless criteria[:reputation].eql?('lude')
      @influencers = @influencers.where(status: reputation_criteria(criteria[:reputation], criteria[:unreviewed]))
    end

    @influencers = @influencers.where("followers #{popularity[0]} ?", popularity[1]) unless popularity[0].eql?('all')

    unless campaign_categories[0].eql?('all')
      @influencers = matched_influencers_based_on_campaign_categories(@influencers, campaign_categories)
    end

    unless criteria[:locations].blank?
      @influencers = filter_influencers_based_on_location(@influencers, criteria[:locations])
    end

    @influencers
  end

  def valid?(verify = false)
    influencer_campaigns = @influencer.offers
    influencer_campaigns = influencer_campaigns.active if verify
    return false if @campaign.paused?

    return false if influencer_campaigns.pluck(:campaign_id).include? @campaign.id

    return false if @campaign.min_score > @influencer.adjusted_score || @campaign.max_score < @influencer.adjusted_score

    return false if @campaign.exclude.present? && @campaign.exclude.include?(@campaign.status)

    if @campaign.locations.present?
      return false if @influencer.zip_code.nil? || @campaign.locations.all? { |l| !l.within?(@influencer.latlon) }
    end

    if @campaign.categories.present? && (@influencer.categories.count.zero? ||
       (@campaign.categories.pluck(:id) & @influencer.categories.pluck(:id)).blank?)
      return false
    end

    return false if @campaign.available_budget < @campaign.sponsor_price(@influencer)

    true
  end

  def verify_valid?
    valid?(true)
  end
end
