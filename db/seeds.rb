admin = User.find_or_create_by!(email: "admin@hans.com") do |u|
  u.password = "password123"
  u.role = "admin"
end

cafe = Customer.find_or_create_by!(email: "cafe@demo.com") do |c|
  c.name = "Café Demo"
  c.contact_name = "Cliente Demo"
  c.phone = "1122334455"
  c.address = "Dirección demo"
  c.active = true
end

User.find_or_create_by!(email: "cafe@demo.com") do |u|
  u.password = "password123"
  u.role = "customer"
  u.customer = cafe
end

DeliverySetting.current.update!(
  cutoff_hour: 0,
  unavailable_weekdays: DeliveryDateValidator.unavailable_weekdays
)

categories = [
  "Mini tartas",
  "Mini tortas",
  "Cuadrados",
  "Cookies",
  "Alfajores",
  "Macarons",
  "Budines",
  "Muffins",
  "Chipa"
]

categories.each_with_index do |name, index|
  Category.find_or_create_by!(name: name) do |c|
    c.position = index + 1
    c.active = true
  end
end

products = [
  ["Mini tartas", "Lemon pie", 4500],
  ["Mini tartas", "Coco y dulce de leche", 4500],
  ["Mini tortas", "Cheesecake frutos rojos", 4700],
  ["Cuadrados", "Brownie", 2800],
  ["Cookies", "Cookie chocolate", 2600],
  ["Alfajores", "Alfajor maicena", 2800],
  ["Macarons", "Macaron frutos rojos", 1700],
  ["Budines", "Budín limón", 17000],
  ["Muffins", "Muffin chocolate", 2500],
  ["Chipa", "Chipa docena congelado", 5000]
]

products.each_with_index do |(category_name, product_name, price), index|
  category = Category.find_by!(name: category_name)

  Product.find_or_create_by!(name: product_name) do |p|
    p.category = category
    p.description = ""
    p.price_cents = price * 100
    p.cost_cents = (price * 0.55).to_i * 100
    p.active = true
    p.position = index + 1
    p.unit = "unidad"
  end
end

puts "Seeds OK"