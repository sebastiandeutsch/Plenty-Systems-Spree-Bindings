Experimental Plenty Systems Spree bindings
==========================================

After month of struggle with the Plenty Systems API I decided to stop using Plenty as a backend
for Spree. Since then, some interesting synchronisation code has been made and I'm releasing it
to whom it may concern.

Attention
=========

The code is highly experimental and the API will vary (as did in the past) and even break -
so probably you'll have to make changes to make it work.

Configuration
=============

Just throw the models into your models folder and create an initializer plenty.rb:

    Plenty.configure do |config|
      config.host      = 'www.example.com'
      config.api_token = 'http://www.example.com$THIS_IS_VERY_SECRET'
    end

Copyright
=========

All code is © 2010, [9elements](http://9elements.com) and is released under the MIT License.
Feel free to email us with any questions or feedback.
