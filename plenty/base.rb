require 'net/http'
require 'net/https'
require 'digest/md5'
require 'iconv'
require 'nokogiri'
require 'stringex'
require 'open-uri'

class Plenty::Base
  def self.reset_database
    Product.connection.execute("TRUNCATE products;")
    Product.connection.execute("TRUNCATE product_option_types;")
    Product.connection.execute("TRUNCATE products_taxons;")
    Asset.connection.execute("TRUNCATE assets;")
    Variant.connection.execute("TRUNCATE variants;")
    OptionType.connection.execute("TRUNCATE option_types;")
    OptionValue.connection.execute("TRUNCATE option_values;")
    OptionValue.connection.execute("TRUNCATE option_values_variants;")
    Taxonomy.connection.execute("TRUNCATE taxonomies;")
    Taxon.connection.execute("TRUNCATE taxons;")
  end
  
  def self.set_stock
    xml  = '<?xml version="1.0" encoding="ISO-8859-1"?>'
    xml << '<StockExport>'
    xml << '<NumIndex index="0">'
    xml << '<article_id>6863</article_id>'
    xml << '<storehouse_id>1</storehouse_id>'
    xml << '<physical_stock>10</physical_stock>'
    xml << '<attribute_set_id>374</attribute_set_id>'
    xml << '</NumIndex>'
    xml << '</StockExport>'
    
    doc = Plenty.configuration.adapter.post('StockXML', {
      :data => xml
    })
    
  end
  
  def self.update_products
    command = 'ArticleBasicXML'
    page = 1
    total_items_processed = 0
    
    loop do
      opts = {
        :additional_params => "params[attribute_set_wanted]=1&params[flag]=11&params[images_wanted]=1&params[no_base64]=1",
        :page              => page
      }
      
      doc = Plenty.configuration.adapter.call(command, opts)
      
      items_per_page = doc.css('NumIndex').size
      items_processed = 0
      (1..items_per_page).each do |i|
        parse_product_document(doc.css("NumIndex:nth-child(#{i})"))
        items_processed += 1
      end
      
      page += 1
      total_items_processed += items_processed
      break if items_processed == 0 
    end
    
    total_items_processed
  end
  
  def self.update_stocks
    command = 'StockXMLAttributeValueSetID'
    page = 1
    total_items_processed = 0
    
    loop do
      opts = {
        :additional_params => "params[storehouse_id]=1",
        :page => page
      }
      
      doc = Plenty.configuration.adapter.call(command, opts)
      
      items_per_page = doc.css('NumIndex').size
      items_processed = 0
      (1..items_per_page).each do |i|
        parse_stock_documment(doc.css("NumIndex:nth-child(#{i})"))
        items_processed += 1
      end
      
      page += 1
      total_items_processed += items_processed
      break if items_processed == 0 
    end
    
    total_items_processed
  end
  
private
  def self.parse_product_document(doc)
    product = parse_product_fields(doc)
    parse_categories_and_add_them_to_product(doc, product)
    parse_attributes_and_add_them_to_product(doc, product)
    parse_images_and_add_them_to_images(doc, product)
  end
  
  def self.parse_stock_documment(doc)
    raw_stock = {
      :article_id             => doc.css("article_id").text.to_i,
      :price_id               => doc.css("price_id").text.to_i,
      :attribute_value_set_id => doc.css("attribute_value_set_id").text.to_i,
      :stock                  => doc.css("stock").text.to_f,
    }

    puts "updating #{raw_stock[:article_id]}-#{raw_stock[:price_id]}-#{raw_stock[:attribute_value_set_id]} to #{raw_stock[:stock]}"
    variant = Variant.find_by_plenty_surrogate_ean("#{raw_stock[:article_id]}-#{raw_stock[:price_id]}-#{raw_stock[:attribute_value_set_id]}")
    if(variant != nil)
      variant.on_hand = raw_stock[:stock]
      variant.save
    end
  end
  
  def self.extract_raw_product(product_doc)
    raw_product = {
      :id          => product_doc.css("id").text.to_i,
      :name        => product_doc.css("DescriptionSet > DescriptionSetNumIndex:first-child > name").text.to_s,
      :description => product_doc.css("DescriptionSet > DescriptionSetNumIndex:first-child > description").text.to_s,
      :keywords    => product_doc.css("keywords").text.to_s,
      :price_id    => product_doc.css("PriceSet > PriceSetNumIndex:first-child > price_id").text.to_i,
      :price       => product_doc.css("PriceSet > PriceSetNumIndex:first-child > price").text.to_f,
      :weight      => product_doc.css("PriceSet > PriceSetNumIndex:first-child > weight").text.to_i
    }
  end
  
  def self.parse_product_fields(product_doc)
    raw_product = extract_raw_product(product_doc)
    
    # create the product
    # @TODO are the plenty article ids together with price unique?
    product = Product.find_by_plenty_article_id_and_plenty_price_id(raw_product[:id], raw_product[:price_id])
    if product.nil?
      product = Product.new(
        :name              => raw_product[:name],
        :description       => raw_product[:description],
        :meta_keywords     => raw_product[:keywords],
        :price             => raw_product[:price],
        :plenty_article_id => raw_product[:id],
        :plenty_price_id   => raw_product[:price_id],
        :available_on      => Time.now
      )
    
      puts "#{raw_product[:id]}-#{raw_product[:price_id]}"
  
      # and master variant
      product.sku = "PS-ID-#{raw_product[:id]}"
      product.on_hand = 0
      product.weight = raw_product[:weight]
      product.save
    else
      product.update_attributes(
        :name              => raw_product[:name],
        :description       => raw_product[:description],
        :meta_keywords     => raw_product[:keywords],
        :price             => raw_product[:price],
        :plenty_article_id => raw_product[:id],
        :plenty_price_id   => raw_product[:price_id]
      )
    end
    
    product
  end
  
  def self.parse_categories_and_add_them_to_product(product_doc, product)
    # get categories
    number_of_categories = product_doc.css("CategoryPathSet > CategoryPathSetNumIndex").size
    (1..number_of_categories).each do |category_index|
      category_doc = product_doc.css("CategoryPathSet > CategoryPathSetNumIndex:nth-child(#{category_index})")
      category_path = category_doc.css('path').text.to_s
      category_path_int = category_doc.css('path_int').text.to_s.split('-')
      
      raw_categories = category_path.split("/")
    
      root_taxonomy = nil
      parent_taxon = nil
      raw_categories.each_with_index do |category_title, i|
        if i<2
          unescaped_title = category_title[1..-2]
          
          if i==0
            root_taxonomy = Taxonomy.find_by_name(unescaped_title)
            if root_taxonomy.nil?
              root_taxonomy = Taxonomy.create!({
                :name      => unescaped_title,
                :plenty_category_id => category_path_int[i],
                :plenty_category_level => i
              })
            end
          end
      
          if parent_taxon.nil?
            taxon = Taxon.find_by_name_and_plenty_category_level(unescaped_title, i)
            if taxon.nil?
              taxon = Taxon.create!({
                :name        => unescaped_title,
                :taxonomy_id => root_taxonomy.id,
                :plenty_category_id => category_path_int[i],
                :plenty_category_level => i
              })
            end
          else
            taxon = Taxon.find_by_name_and_plenty_category_level(unescaped_title, i)
            if taxon.nil?
              taxon = Taxon.create!({
                :name        => unescaped_title,
                :taxonomy_id => root_taxonomy.id,
                :parent_id   => parent_taxon.id,
                :plenty_category_id => category_path_int[i],
                :plenty_category_level => i
              })
            end
          end
          
          parent_taxon = taxon
        end
      end
      
      # only add if it's not added already
      product.taxons << parent_taxon if product.taxons.find_by_id(parent_taxon.id).nil?
    end
  end
  
  def self.parse_attributes_and_add_them_to_product(product_doc, product)
    raw_product = extract_raw_product(product_doc)
    
    # get attributes
    number_of_attributes = product_doc.css("AttributeValueSet > AttributeValueSetNumIndex").size
    (1..number_of_attributes).each do |attribute_index|
      attribute_doc = product_doc.css("AttributeValueSet > AttributeValueSetNumIndex:nth-child(#{attribute_index})")
      raw_attribute = {
        :avset_id => attribute_doc.css("avset_id").text.to_i,
        :name     => attribute_doc.css("attribute_selection").text.to_s.split(':')[0],
        :value    => attribute_doc.css("attribute_selection").text.to_s.split(':')[1],
        :short    => attribute_doc.css("attribute_selection_short").text.to_s,
        :ean      => attribute_doc.css("ean").text.to_s
      }
    
      # ignore if no ean is set
      if raw_attribute[:ean] != ""
        # whywhywhy we have to do mapping
        # if raw_attribute[:value] == "Groesse"
        #   raw_attribute[:value] = "Größe"
        # end
        # please fix this in plenty!!11

        # check if we already have that option type
        option_type = OptionType.find_by_presentation(raw_attribute[:name])
        if option_type.nil?
          option_type = OptionType.create!(
            :name         => raw_attribute[:name].to_url,
            :presentation => raw_attribute[:name]
          )          
        end
    
        product.option_types << option_type if product.option_types.find_by_id(option_type.id).nil?
    
        option_value = OptionValue.find_by_presentation(raw_attribute[:value])
      
        if option_value.nil?
          option_value = OptionValue.create!(
            :name                          => raw_attribute[:value].to_url,
            :presentation                  => raw_attribute[:value],
            :option_type_id                => option_type.id,
            :plenty_attribute_value_set_id => raw_attribute[:avset_id]
          )
        end
        
        variant = Variant.find_by_plenty_surrogate_ean("#{product.plenty_article_id}-#{product.plenty_price_id}-#{raw_attribute[:avset_id]}")
        if variant.nil?
          variant = product.variants.create(
            :sku                           => raw_attribute[:ean],
            :price                         => raw_product[:price],
            :weight                        => raw_product[:weight],
            :plenty_article_id             => product.plenty_article_id,
            :plenty_price_id               => product.plenty_price_id,
            :plenty_attribute_value_set_id => raw_attribute[:avset_id],
            :plenty_surrogate_ean          => "#{product.plenty_article_id}-#{product.plenty_price_id}-#{raw_attribute[:avset_id]}",
            :on_hand => 0
          )
        end

        variant.option_values << option_value if variant.option_values.find_by_id(option_value.id).nil?
      end
    end
  end
  
  # 
  
  def self.parse_images_and_add_them_to_images(product_doc, product)
    # get images
    number_of_images = product_doc.css("ImageSet > ImageSetNumIndex").size
    (1..number_of_images).each do |image_index|
      image_doc = product_doc.css("ImageSet > ImageSetNumIndex:nth-child(#{image_index})")
    
      raw_image = {
        :url  => image_doc.css("image_url").text.to_s,
        :name => image_doc.css("imagename").text.to_s
      }
    
      begin
        if Image.find_by_attachment_file_name(raw_image[:name]).nil?
          image = Image.new(:viewable_id => product.id, :viewable_type => 'Product')
          image.attachment = open(URI.parse(raw_image[:url]))
          image.attachment_file_name = raw_image[:name]
          image.save
        end
      rescue Timeout::Error
      end
    end
  end
end
